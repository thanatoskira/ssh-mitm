#!/bin/bash

openssh_sources='openssh-7.5p1.tar.gz'
openssh_source_dir='openssh-7.5p1'
mitm_patch='openssh-7.5p1-mitm.patch'


# Installs prerequisites.
function install_prereqs() {
    echo -e "Installing prerequisites...\n"
    apt -y install libssl-dev zlib1g-dev build-essential
    if [[ $? != 0 ]]; then
        echo -e "Failed to install prerequisites.  Failed: apt -y install libssl-dev zlib1g-dev build-essential"
        exit -1
    fi

    return 1
}


# Downloads OpenSSH and verifies its sources.
function get_openssh {
    local openssh_sig='openssh-7.5p1.tar.gz.asc'
    local openssh_signature_date='Signature made Mon 20 Mar 2017 05:53:10 AM EDT using RSA key ID 6D920D30'
    local release_key_fingerprint_expected='59C2 118E D206 D927 E667  EBE3 D3E5 F56B 6D92 0D30'
    local openssh_checksum_expected='9846e3c5fab9f0547400b4d2c017992f914222b3fd1f8eee6c7dc6bc5e59f9f0'

    rm -rf RELEASE_KEY.asc openssh-*.tar.gz* openssh-*/

    echo -e "\nGetting OpenSSH release key...\n"
    wget https://ftp.openbsd.org/pub/OpenBSD/OpenSSH/RELEASE_KEY.asc

    echo -e "\nGetting OpenSSH sources...\n"
    wget https://ftp.openbsd.org/pub/OpenBSD/OpenSSH/portable/$openssh_sources

    echo -e "\nGetting OpenSSH signature...\n"
    wget https://ftp.openbsd.org/pub/OpenBSD/OpenSSH/portable/$openssh_sig

    echo -e "\nImporting OpenSSH release key...\n"
    gpg --import RELEASE_KEY.asc

    local release_key_fingerprint_actual=`gpg --fingerprint 6D920D30`
    if [[ $release_key_fingerprint_actual != *"Key fingerprint = $release_key_fingerprint_expected"* ]]; then
        echo -e "\nError: OpenSSH release key fingerprint does not match expected value!\n\tExpected: $release_key_fingerprint_expected\n\tActual: $release_key_fingerprint_actual\n\nTerminating."
        exit -1
    fi
    echo -e "\n\nOpenSSH release key matches expected value.\n"

    local gpg_verify=`gpg --verify $openssh_sig $openssh_sources 2>&1`
    if [[ $gpg_verify != *"$openssh_signature_date"*"Good signature from \"Damien Miller <djm@mindrot.org>\""* ]]; then
        echo -e "\n\nError: OpenSSH signature invalid!\n$gpg_verify\n\nTerminating."
        rm -f $openssh_sources
        exit -1
    fi
    echo -e "Signature on OpenSSH sources verified.\n"

    local openssh_checksum_actual=`sha256sum $openssh_sources`
    if [[ $openssh_checksum_actual != "$openssh_checksum_expected"* ]]; then
        echo -e "Error: OpenSSH checksum is invalid!  Terminating."
        exit -1
    fi

    return 1
}


# Applies the MITM patch to OpenSSH and compiles it.
function compile_openssh {
    tar xzf $openssh_sources
    if [ ! -d $openssh_source_dir ]; then
       echo "Failed to decompress OpenSSH sources!"
       exit -1
    fi
    mv $openssh_source_dir "$openssh_source_dir"-mitm
    openssh_source_dir="$openssh_source_dir"-mitm

    pushd $openssh_source_dir > /dev/null
    echo -e "Patching OpenSSH sources...\n"
    patch -p1 < ../$mitm_patch

    if [[ $? != 0 ]]; then
        echo "Failed to patch sources!: patch returned $?"
        exit -1
    fi

    echo -e "\nDone.  Compiling modified OpenSSH sources...\n"
    ./configure --with-sandbox=no --with-privsep-path=/home/ssh-mitm/empty --with-pid-dir=/home/ssh-mitm --with-lastlog=/home/ssh-mitm
    make -j `nproc --all`
    popd > /dev/null
}


# Creates the ssh-mitm user account, and sets up its environment.
function setup_environment {
    echo -e "\nCreating ssh-mitm user, and setting up its environment...\n"
    useradd -m -s /bin/bash ssh-mitm
    chmod 0700 ~ssh-mitm
    cp $openssh_source_dir/sshd_config ~ssh-mitm
    cp $openssh_source_dir/sshd ~ssh-mitm/sshd_mitm
    cp $openssh_source_dir/ssh ~ssh-mitm/ssh
    ssh-keygen -t rsa -b 4096 -f /home/ssh-mitm/ssh_host_rsa_key -N ''
    ssh-keygen -t ed25519 -f /home/ssh-mitm/ssh_host_ed25519_key -N ''
    mkdir -m 0700 ~ssh-mitm/empty
    chown ssh-mitm:ssh-mitm /home/ssh-mitm/empty /home/ssh-mitm/ssh_host_*key*
    cat > ~ssh-mitm/run.sh <<EOF
#!/bin/bash
/home/ssh-mitm/sshd_mitm -f /home/ssh-mitm/sshd_config
if [[ $? == 0 ]]; then
    echo "sshd_mitm is running.  Now update the PREROUTING table, begin ARP spoofing, and credentials should start rolling into /var/log/auth.log.  See README.md for more information."
fi
EOF
    chmod 0755 ~ssh-mitm/run.sh
}


if [[ `id -u` != 0 ]]; then
    echo "Error: this script must be run as root."
    exit -1
fi

install_prereqs
get_openssh
compile_openssh
setup_environment
exit 0