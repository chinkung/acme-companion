#!/bin/bash

set -u

# shellcheck source=functions.sh
source /app/functions.sh

function print_version {
    if [[ -n "${COMPANION_VERSION:-}" ]]; then
        echo "Info: running acme-companion version ${COMPANION_VERSION}"
    fi
}

function check_docker_socket {
    if [[ $DOCKER_HOST == unix://* ]]; then
        socket_file=${DOCKER_HOST#unix://}
        if [[ ! -S $socket_file ]]; then
            if [[ ! -r $socket_file ]]; then
                echo "Warning: Docker host socket at $socket_file might not be readable. Please check user permissions" >&2
                echo "If you are in a SELinux environment, try using: '-v /var/run/docker.sock:$socket_file:z'" >&2
            fi
            echo "Error: you need to share your Docker host socket with a volume at $socket_file" >&2
            echo "Typically you should run your container with: '-v /var/run/docker.sock:$socket_file:ro'" >&2
            exit 1
        fi
    fi
}

function check_dir_is_mounted_volume {
    local dir="$1"
    if [[ $(get_self_cid) ]]; then
        if ! docker_api "/containers/$(get_self_cid)/json" | jq ".Mounts[].Destination" | grep -q "^\"$dir\"$"; then
            echo "Warning: '$dir' does not appear to be a mounted volume."
        fi
    else
        echo "Warning: can't check if '$dir' is a mounted volume without self container ID."
    fi
}

function check_writable_directory {
    local dir="$1"

    check_dir_is_mounted_volume "$dir"

    if [[ ! -d "$dir" ]]; then
        echo "Error: can't access to '$dir' directory !" >&2
        echo "Check that '$dir' directory is declared as a writable volume." >&2
        exit 1
    fi
    if ! touch "$dir/.check_writable" 2>/dev/null ; then
        echo "Error: can't write to the '$dir' directory !" >&2
        echo "Check that '$dir' directory is export as a writable volume." >&2
        exit 1
    fi
    rm -f "$dir/.check_writable"
}

function warn_html_directory {
    local dir='/usr/share/nginx/html'
    
    check_dir_is_mounted_volume "$dir"

    if [[ ! -d "$dir" ]] || ! touch "$dir/.check_writable" 2>/dev/null; then
        echo "Warning: can't access or write to '$dir' directory. This will prevent HTML-01 challenges from working correctly."
        echo "If you are only using DNS-01 challenges, you can ignore this warning, otherwise check that '$dir' is declared as a writable volume."
    fi
    rm -f "$dir/.check_writable"
}

function check_dh_group {
	# DH params will be supplied for acme-companion here:
	local DHPARAM_FILE='/etc/nginx/certs/dhparam.pem'

	# Should be 2048, 3072, or 4096 (default):
	local DHPARAM_BITS="${DHPARAM_BITS:=4096}"

    # Skip generation if DHPARAM_SKIP is set to true
    if parse_true "${DHPARAM_SKIP:=false}"; then
		echo "Info: Skipping Diffie-Hellman group setup."
		return 0
    fi

    # Let's check DHPARAM_BITS is set to a supported value
    if [[ ! "$DHPARAM_BITS" =~ ^(2048|3072|4096)$ ]]; then
        echo "Error: Unsupported DHPARAM_BITS size: ${DHPARAM_BITS}. Supported values are 2048, 3072, or 4096 (default)." >&2
        exit 1
    fi

    # Use an existing pre-generated DH group from RFC7919 (https://datatracker.ietf.org/doc/html/rfc7919#appendix-A):
    local RFC7919_DHPARAM_FILE="/app/dhparam/ffdhe${DHPARAM_BITS}.pem"
    local EXPECTED_DHPARAM_HASH; EXPECTED_DHPARAM_HASH=$(sha256sum "$RFC7919_DHPARAM_FILE" | cut -d ' ' -f1)

	# DH params may be provided by the user (rarely necessary)
	if [[ -f "$DHPARAM_FILE" ]]; then
        local USER_PROVIDED_DH

        # Check if the DH params file is user provided or comes from acme-companion
        local DHPARAM_HASH; DHPARAM_HASH=$(sha256sum "$DHPARAM_FILE" | cut -d ' ' -f1)
        
        for f in /app/dhparam/ffdhe*.pem; do
            local FFDHE_HASH; FFDHE_HASH=$(sha256sum "$f" | cut -d ' ' -f1)
            if [[ "$DHPARAM_HASH" == "$FFDHE_HASH" ]]; then
                # This is an acme-companion created DH params file
                USER_PROVIDED_DH='false'

                # Check if /etc/nginx/certs/dhparam.pem matches the expected pre-generated DH group
                if [[ "$DHPARAM_HASH" == "$EXPECTED_DHPARAM_HASH" ]]; then
                    set_ownership_and_permissions "$DHPARAM_FILE"
                    echo "Info: ${DHPARAM_BITS} bits RFC7919 Diffie-Hellman group found, generation skipped."
                    return 0
                fi
            fi
        done

        if parse_true "${USER_PROVIDED_DH:=true}"; then
            # This is a user provided DH params file
            set_ownership_and_permissions "$DHPARAM_FILE"
            echo "Info: A custom dhparam.pem file was provided. Best practice is to use standardized RFC7919 Diffie-Hellman groups instead."
            return 0
        fi
	fi

    # The RFC7919 DH params file either need to be created or replaced
	echo "Info: Setting up ${DHPARAM_BITS} bits RFC7919 Diffie-Hellman group..."
	cp "$RFC7919_DHPARAM_FILE" "${DHPARAM_FILE}.tmp"
    mv "${DHPARAM_FILE}.tmp" "$DHPARAM_FILE"
    set_ownership_and_permissions "$DHPARAM_FILE"
}

function check_default_cert_key {
    local cn='acme-companion'

    echo "Warning: there is no future support planned for the self signed default certificate creation feature and it might be removed in a future release."

    if [[ -e /etc/nginx/certs/default.crt && -e /etc/nginx/certs/default.key ]]; then
        default_cert_cn="$(openssl x509 -noout -subject -in /etc/nginx/certs/default.crt)"
        # Check if the existing default certificate is still valid for more
        # than 3 months / 7776000 seconds (60 x 60 x 24 x 30 x 3).
        check_cert_min_validity /etc/nginx/certs/default.crt 7776000
        cert_validity=$?
        [[ "$DEBUG" == 1 ]] && echo "Debug: a default certificate with $default_cert_cn is present."
    fi

    # Create a default cert and private key if:
    #   - either default.crt or default.key are absent
    #   OR
    #   - the existing default cert/key were generated by the container
    #     and the cert validity is less than three months
    if [[ ! -e /etc/nginx/certs/default.crt || ! -e /etc/nginx/certs/default.key ]] || [[ "${default_cert_cn:-}" =~ $cn && "${cert_validity:-}" -ne 0 ]]; then
        openssl req -x509 \
            -newkey rsa:4096 -sha256 -nodes -days 365 \
            -subj "/CN=$cn" \
            -keyout /etc/nginx/certs/default.key.new \
            -out /etc/nginx/certs/default.crt.new \
        && mv /etc/nginx/certs/default.key.new /etc/nginx/certs/default.key \
        && mv /etc/nginx/certs/default.crt.new /etc/nginx/certs/default.crt \
        && reload_nginx
        echo "Info: a default key and certificate have been created at /etc/nginx/certs/default.key and /etc/nginx/certs/default.crt."
    elif [[ "$DEBUG" == 1 && "${default_cert_cn:-}" =~ $cn ]]; then
        echo "Debug: the self generated default certificate is still valid for more than three months. Skipping default certificate creation."
    elif [[ "$DEBUG" == 1 ]]; then
        echo "Debug: the default certificate is user provided. Skipping default certificate creation."
    fi
    set_ownership_and_permissions "/etc/nginx/certs/default.key"
    set_ownership_and_permissions "/etc/nginx/certs/default.crt"
}

function check_default_account {
    # The default account is now for empty account email
    if [[ -f /etc/acme.sh/default/account.conf ]]; then
        if grep -q ACCOUNT_EMAIL /etc/acme.sh/default/account.conf; then
            sed -i '/ACCOUNT_EMAIL/d' /etc/acme.sh/default/account.conf
        fi
    fi
}

if [[ "$*" == "/bin/bash /app/start.sh" ]]; then
    print_version
    check_docker_socket
    if [[ -z "$(get_nginx_proxy_container)" ]]; then
        echo "Error: can't get nginx-proxy container ID !" >&2
        echo "Check that you are doing one of the following :" >&2
        echo -e "\t- Use the --volumes-from option to mount volumes from the nginx-proxy container." >&2
        echo -e "\t- Set the NGINX_PROXY_CONTAINER env var on the letsencrypt-companion container to the name of the nginx-proxy container." >&2
        echo -e "\t- Label the nginx-proxy container to use with 'com.github.nginx-proxy.nginx'." >&2
        exit 1
    elif [[ -z "$(get_docker_gen_container)" ]] && ! is_docker_gen_container "$(get_nginx_proxy_container)"; then
        echo "Error: can't get docker-gen container id !" >&2
        echo "If you are running a three containers setup, check that you are doing one of the following :" >&2
        echo -e "\t- Set the NGINX_DOCKER_GEN_CONTAINER env var on the letsencrypt-companion container to the name of the docker-gen container." >&2
        echo -e "\t- Label the docker-gen container to use with 'com.github.nginx-proxy.docker-gen'." >&2
        exit 1
    fi
    check_writable_directory '/etc/nginx/certs'
    parse_true "${ACME_HTTP_CHALLENGE_LOCATION:=false}" && check_writable_directory '/etc/nginx/vhost.d'
    check_writable_directory '/etc/acme.sh'
    warn_html_directory
    if [[ -f /app/letsencrypt_user_data ]]; then
        check_writable_directory '/etc/nginx/vhost.d'
        check_writable_directory '/etc/nginx/conf.d'
    fi
    parse_true "${CREATE_DEFAULT_CERTIFICATE:=false}" && check_default_cert_key
    check_dh_group
    reload_nginx
    check_default_account
fi

exec "$@"
