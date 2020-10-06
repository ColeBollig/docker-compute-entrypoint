#!/bin/bash -xe

BOSCO_KEY=/etc/osg/bosco.key
# $REMOTE_HOST needs to be specified in the environment
remote_fqdn=${REMOTE_HOST%:*}
if [[ $REMOTE_HOST =~ :[0-9]+$ ]]; then
    remote_port=${REMOTE_HOST#*:}
else
    remote_port=22
fi
REMOTE_HOST_KEY=`ssh-keyscan -p "$remote_port" -H "$remote_fqdn"`
ENDPOINT_CONFIG=/etc/endpoints.ini

function errexit {
    echo "$1" >&2
    exit 1
}

setup_ssh_config () {
  echo "Adding user ${ruser}"
  ssh_dir="/home/${ruser}/.ssh"
  # setup user and SSH dir
  adduser --base-dir /home/ "${ruser}"
  mkdir -p $ssh_dir
  chown "${ruser}": $ssh_dir
  chmod 700 $ssh_dir

  # copy Bosco key
  ssh_key=$ssh_dir/bosco_key.rsa
  cp $BOSCO_KEY $ssh_key
  chmod 600 $ssh_key
  chown "${ruser}": $ssh_key
  cat <<EOF > $ssh_dir/config
IdentitiesOnly yes
Host $remote_fqdn
  Port $remote_port
  IdentityFile ${ssh_key}
EOF

  # setup known hosts
  echo $REMOTE_HOST_KEY >> $ssh_dir/known_hosts

  for ssh_file in $ssh_dir/config $ssh_dir/known_hosts; do
      chown "${ruser}": $ssh_file
  done

  # debugging
  ls -l "$ssh_dir"
}

# Install the WN client, CAs, and CRLs on the remote host
# Store logs in /var/log/condor-ce/ to simplify serving logs via Kubernetes
setup_endpoints_ini () {
    remote_home_dir=$(ssh -q -i $BOSCO_KEY "${ruser}@$remote_fqdn" pwd)
    remote_os_ver=$(ssh -q -i $BOSCO_KEY "${ruser}@$remote_fqdn" "rpm -E %rhel")
    osg_ver=3.4
    if [[ $remote_os_ver -gt 6 ]]; then
        osg_ver=3.5
    fi
    cat <<EOF >> $ENDPOINT_CONFIG
[Endpoint ${RESOURCE_NAME}-${ruser}]
local_user = ${ruser}
remote_host = $remote_fqdn
remote_user = ${ruser}
remote_dir = $remote_home_dir/bosco-osg-wn-client
upstream_url = https://repo.opensciencegrid.org/tarball-install/${osg_ver}/osg-wn-client-latest.el${remote_os_ver}.x86_64.tar.gz
EOF
}

# Set the appropriate SSH key for bosco_cluster commands
root_ssh_dir=/root/.ssh/
mkdir -p $root_ssh_dir
chmod 700 $root_ssh_dir
cat <<EOF > $root_ssh_dir/config
Host $remote_fqdn
  Port $remote_port
  IdentityFile ${BOSCO_KEY}
EOF
echo $REMOTE_HOST_KEY >> $root_ssh_dir/known_hosts

# Populate the bosco override dir from a Git repo
if [[ -n $BOSCO_GIT_ENDPOINT && -n $BOSCO_DIRECTORY ]]; then
    OVERRIDE_DIR=/etc/condor-ce/bosco_override
    /usr/local/bin/bosco-override-setup.sh "$BOSCO_GIT_ENDPOINT" "$BOSCO_DIRECTORY" /etc/osg/git.key
fi
unset GIT_SSH_COMMAND

users=$(cat /etc/grid-security/grid-mapfile /etc/grid-security/voms-mapfile | \
            awk '/^"[^"]+" +[a-zA-Z0-9\-\._]+$/ {print $NF}' | \
            sort -u)
[[ -n $users ]] || errexit "Did not find any user mappings in the VOMS or Grid mapfiles"

# Allow the condor user to run the WN client updater as the local users
CONDOR_SUDO_FILE=/etc/sudoers.d/10-condor-ssh
condor_sudo_users=`tr ' ' ',' <<< $users`
echo "condor ALL = ($condor_sudo_users) NOPASSWD: /usr/bin/update-remote-wn-client" \
      > $CONDOR_SUDO_FILE
chmod 644 $CONDOR_SUDO_FILE

grep '^OSG_GRID="/cvmfs/oasis.opensciencegrid.org/osg-software/osg-wn-client' \
     /var/lib/osg/job-environment*.conf > /dev/null 2>&1
cvmfs_wn_client=$?

# Enable bosco_cluster debug output
bosco_cluster_opts=(-d )
if [[ -n $OVERRIDE_DIR ]]; then
    if [[ -d $OVERRIDE_DIR ]]; then
        bosco_cluster_opts+=(-o "$OVERRIDE_DIR")
    else
        echo "WARNING: $OVERRIDE_DIR is not a directory. Skipping Bosco override."
    fi
fi

[[ $REMOTE_BOSCO_DIR ]] && bosco_cluster_opts+=(-b "$REMOTE_BOSCO_DIR") \
        || REMOTE_BOSCO_DIR=bosco

echo "Using Bosco tarball: $(bosco_findplatform --url)"
for ruser in $users; do
    setup_ssh_config
    [[ $cvmfs_wn_client -eq 0 ]] || setup_endpoints_ini
    # $REMOTE_BATCH needs to be specified in the environment
    bosco_cluster "${bosco_cluster_opts[@]}" -a "${ruser}@$remote_fqdn" "$REMOTE_BATCH"

    # Copy over environment files to allow for dynamic WN variables (SOFTWARE-4117)
    rsync -av /var/lib/osg/osg-*job-environment.conf \
          "${ruser}@$REMOTE_HOST:$REMOTE_BOSCO_DIR/glite/etc"
done

[[ $cvmfs_wn_client -eq 0 ]] || sudo -u condor update-all-remote-wn-clients --log-dir /var/log/condor-ce/
