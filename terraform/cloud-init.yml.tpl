#cloud-config

users:
  - name: ${username}
    groups: sudo, docker
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${ssh_public_key}

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
  - path: /etc/fail2ban/jail.local
    content: |
      [sshd]
      enabled = true
      port = ${ssh_port}
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
      ExecStart=/usr/bin/docker compose up -d --build
      ExecStop=/usr/bin/docker compose down

      [Install]
      WantedBy=multi-user.target

runcmd:
  # SSH hardening - change port and restart before enabling firewall
  - sed -i 's/^#\?Port .*/Port ${ssh_port}/' /etc/ssh/sshd_config
  - sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
  - sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
  - systemctl restart ssh

  # UFW firewall - only enable after SSH is on the new port
  - ufw default deny incoming
  - ufw default allow outgoing
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

  # Clone repo and start services
  - git clone ${repo_url} /home/${username}/dev-lab
  - chown -R ${username}:${username} /home/${username}/dev-lab
  - systemctl daemon-reload
  - systemctl enable dev-lab
  - systemctl start dev-lab
