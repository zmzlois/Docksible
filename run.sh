#!/usr/bin/env bash

set -euo pipefail

# generate a random string with number for container's name 
identifier="$(< /dev/urandom tr -dc 'a-z0-9' | fold -w 5 | head -n 1)" ||:
# name of the container, you can give it whatever name you want
NAME="docksible-${identifier}"
# get the absolute path of the script but only the directory
project_dir="$(dirname "$(readlink -f "$0")")"

# Confirm this is the desire directory
echo "base directory: ${project_dir}"

# a cleanup function which will be able to clean up the temporary folder and the container as well.

function cleanup() {
    # Retreive the container id based on its name, with ||: at the end make sure command doesn't exit if there is an error (container doesn't exist etc)
    container_id=$(docker inspect --format="{{.Id}}" "${NAME}" ||:)
    # if the container_id variable is not empty
    if [[ -n "${container_id}" ]]; then

        echo "Cleaning up container ${NAME}"
        # force remove container
        docker rm --force "${container_id}"
    fi
    # check if TEMP_DIR variable not empty and does it represent a directory
    # this file by creation (in this script) includes SSH key, inventory file
    if [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR:-}" ]]; then
        echo "Cleaning up tepdir ${TEMP_DIR}"
        rm -rf "${TEMP_DIR}"
    fi
}

# We add a function to create temporary directory to store our temporary assets (like the inventory and the ssh id).
function setup_tempdir() {
    # XXXXXXX - placeholder for randomly generated string
    TEMP_DIR=$(mktemp --directory "/tmp/${NAME}".XXXXXXXX)
    export TEMP_DIR
}

# create ssh identities so Ansible can access the container through ssh. During docker build these will be added inside the container by a COPY step (see above in the Dockerfile).
function create_temporary_ssh_id() {
    # -b 2048 number of bits in the key
    # -t rsa type of key 
    # -C "${USER}@email.com" adds a comment to the key
    ssh-keygen -b 2048 -t rsa -C "${USER}@email.com" -f "${TEMP_DIR}/id_rsa" -N ""
    # sets permission of the private key file to read and write for owner only
    chmod 600 "${TEMP_DIR}/id_rsa"
    # sets permision of the public key file to read and write for the owner and read-only for others
    chmod 644 "${TEMP_DIR}/id_rsa.pub"
}
# We build and start the container with this function - providing the TEMP_DIR as it's context. We figure out the container's address for ssh.
function start_container() {
    docker build --tag "docksible" \
        --build-arg USER \ 
        --file "${project_dir}/Dockerfile" \
        "${TEMP_DIR}"
        # run it in detach mode and map it to port 2222 at localhost so ansible can find it
    docker run -d -p 127.0.0.1:2222:22 --name "${NAME}" "docksible"

    # CONTAINER_ADDR=$(docker inspect --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${NAME}")
    # echo "container_addr ${CONTAINER_ADDR}"
    # export CONTAINER_ADDR
}

function setup_test_inventory() {
    TEMP_INVENTORY_FILE="${TEMP_DIR}/hosts"
   # uses the cat command to create the content of the Ansible inventory file. 
   # The content is generated between the << EOL and EOL markers and is written to the file specified by ${TEMP_INVENTORY_FILE}.
    cat > "${TEMP_INVENTORY_FILE}" << EOL
[target_group]
127.0.0.1:2222
[target_group:vars]
ansible_ssh_private_key_file=${TEMP_DIR}/id_rsa
EOL
    export TEMP_INVENTORY_FILE
}

function run_ansible_playbook() {
    ANSIBLE_CONFIG="${project_dir}/ansible.cfg"
    # -i "${TEMP_INVENTORY_FILE}": Specifies the path to the Ansible inventory file. 
    # -vvv: Increases the verbosity level of the playbook execution. prints more detailed information about the playbook run.
    # "${project_dir}/playbook.yml": Specifies the path to the Ansible playbook file (playbook.yml). 
    ansible-playbook -i "${TEMP_INVENTORY_FILE}" -vvv "${project_dir}/playbook.yml"
}

setup_tempdir
trap cleanup EXIT
trap cleanup ERR
create_temporary_ssh_id
start_container
setup_test_inventory
run_ansible_playbook