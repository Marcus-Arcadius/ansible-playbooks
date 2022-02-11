# Exit on any error
set -e

# Set function to be called on exit
trap 'on_exit $?' EXIT

###############################################################################
# on_exit is called at exit, if there was an error it logs an error.
# Globals: none
# Parameters:
# - $1: Script exit code
###############################################################################
on_exit() {
  popd > /dev/null

  # Log an error
  if [ "$1" != "0" ]; then
    echo "ERROR: Error $1"
  else
    echo "SUCCESS: Command finished successfully"
  fi
  exit $1
}

# Get root ansible dir
ans_dir=$(dirname "$0")/..
pushd $ans_dir > /dev/null

# Configs
# Current Ansible Control Machine image
ansiblecm_image='skynetlabs/ansiblecm:ansible-3.1.0-skynetlabs-0.7.0'

# To allow running 2 or more parallel ansiblecm containers running from
# different directories (having mounted different directories) we need to
# distinguish them via docker container postfix. Postfix is based on the
# checksum of the current ansible playbooks directory.
container_postfix=$(docker run alpine sh -c "echo '$ans_dir' | cksum | cut -d ' ' -f 1")
ansiblecm_container=ansiblecm-$container_postfix

# Set LastPass session timeout
if [ -z "$lpass_timeout" ]; then
  lpass_timeout=$default_lpass_timeout_secs
fi

# Check if wanted image runs for the given directory
if docker ps -a --no-trunc --format "table {{.Image}} {{.Names}}" | grep "^$ansiblecm_image $ansiblecm_container$" > /dev/null; then
  echo "Ansible Control Machine is already running"
else
  # Stop Ansible containers running on older/non-wanted docker images
  # - list all docker container names
  # - get only ansible control machines (belonging to this ansible playbooks directory)
  # - stop containers if found
  echo "Stopping Ansible Control Machine (if running)..."
  docker ps -a --no-trunc --format "table {{.Names}}" | grep "^$ansiblecm_container$" | xargs -r docker stop > /dev/null

  # Start current version
  echo "Starting Ansible Control Machine..."

  # Start Ansible Control Machine and keep it running. This is especially
  # needed for LastPass session.
  # Volume and env var with SSH_AUTH_SOCK is used so we can perform SSH agent
  # forwarding from local machine (a docker host machine) to Ansible Control
  # Machine in docker which can then perform SSH agent forwarding between
  # remote hosts.
  docker run -it --rm \
    --entrypoint sleep \
    -e ANSIBLE_STDOUT_CALLBACK=debug \
    -e LPASS_AGENT_TIMEOUT=$lpass_timeout \
    -v ~/.ssh:/root/.ssh:ro \
    -v $SSH_AUTH_SOCK:/ssh-agent \
    -v $(pwd):/tmp/playbook:Z \
    -v $(pwd)/../ansible-private:/tmp/ansible-private \
    -v /tmp/SkynetLabs-ansible:/tmp/SkynetLabs-ansible \
    -v /var/run/docker.sock:/var/run/docker.sock \
    --env SSH_AUTH_SOCK=/ssh-agent \
    --detach \
    --name $ansiblecm_container \
    $ansiblecm_image \
    infinity > /dev/null
fi

# Update Ansible requirements (Ansible roles and collections) if not up-to-date
# Get the latest git commit of ./requirements.yml file
requirements_commit=$(git log -n 1 --pretty=format:%H -- requirements.yml)

# Get the git commit of the latest installed requirements
requirements_installed_file=my-logs/requirements-installed.txt
if [ -f "$requirements_installed_file" ]; then
    requirements_installed=$(cat $requirements_installed_file)
fi

# Install requirements
if [ "$requirements_installed" = "$requirements_commit" ]; then
    echo "Ansible requirements (roles and collections) are up-to-date"
else
    echo "Updating Ansible requirements (roles and collections)..."
    docker exec $ansiblecm_container ansible-galaxy install -r requirements.yml --force
    echo $requirements_commit > $requirements_installed_file
fi

# Execute the playbook from Ansible CM in a Docker container
echo "Executing:"
echo "    $cmd $args"
echo "in a docker container..."

docker exec -it $ansiblecm_container $cmd $args