#cloud-config

groups:
  - docker

users:
  - name: ${username}
    groups:
      - sudo
      - docker
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - ${ssh_public_key}

ssh_pwauth: false

package_update: true
package_upgrade: true

packages:
  - ufw
  - fail2ban
  - unattended-upgrades
  - apt-transport-https
  - ca-certificates
  - curl
  - gnupg
  - git

write_files:
  - path: /etc/ssh/sshd_config.d/60-dev-lab.conf
    content: |
      Port ${ssh_port}
      PermitRootLogin no
      PasswordAuthentication no

  - path: /etc/fail2ban/jail.local
    content: |
      [sshd]
      enabled = true
      port = ssh,${ssh_port}
      filter = sshd
      logpath = /var/log/auth.log
      maxretry = 5
      bantime = 3600

  - path: /etc/apt/apt.conf.d/20auto-upgrades
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";

  - path: /etc/systemd/system/dev-lab.service
    content: |
      [Unit]
      Description=dev-lab docker compose stack
      Requires=docker.service
      After=docker.service

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      User=${username}
      WorkingDirectory=/home/${username}/dev-lab
      Environment=SKIP_GIT_PULL=1
      ExecStart=/home/${username}/dev-lab/scripts/deploy.sh
      ExecStop=/usr/bin/docker compose down

      [Install]
      WantedBy=multi-user.target

runcmd:
  # Validate the SSH drop-in before restarting so a bad config does not brick access.
  - /bin/sh -c 'sshd -t && systemctl restart ssh'

  # Keep 22 open as a recovery path in case the custom port change does not apply.
  - ufw default deny incoming
  - ufw default allow outgoing
  - ufw allow 22/tcp
  - ufw allow ${ssh_port}/tcp
  - ufw allow 80/tcp
  - ufw allow 443/tcp
  - ufw --force enable

  # Fail2ban
  - systemctl enable fail2ban
  - systemctl restart fail2ban

  # Install Docker
  - install -m 0755 -d /etc/apt/keyrings
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  - chmod a+r /etc/apt/keyrings/docker.asc
  - |
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
  - apt-get update
  - apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

  # Create the webhook env dir owned by the service user so docker compose
  # (invoked as ${username}) can read env_file paths. The secrets file
  # itself must be populated out-of-band by the operator on first boot
  # before the webhook service can pass authenticated hooks through.
  - install -m 0700 -o ${username} -g ${username} -d /etc/dev-lab
  - install -m 0600 -o ${username} -g ${username} /dev/null /etc/dev-lab/webhook.env

  # Clone repo and start services
  - git clone ${repo_url} /home/${username}/dev-lab
  - chown -R ${username}:${username} /home/${username}/dev-lab
  - systemctl daemon-reload
  - systemctl enable dev-lab
  - systemctl start dev-lab
