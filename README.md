# linux-ad-join
A lightweight, multi-distro automation script to join Linux systems to Active Directory domains. Configures realm, SSSD, and Kerberos, sets up users and groups, handles home directories, SSH, and access rules. Supports servers and workstations with logging and automatic or prompted reboots.
Linux AD Join is a lightweight, open-source script that simplifies the process of joining Linux machines to Active Directory (AD) domains.

It automates the installation and configuration of all required packages such as realm, SSSD, Kerberos, and Oddjob, and dynamically sets up:

Hostname configuration

Secure SSSD settings with simple_allow_users and simple_allow_groups

Automatic home directory creation for domain users

SSH configuration for password authentication

Domain access rules using realm permit

The script is designed to work across multiple Linux distributions, including:

Ubuntu / Debian-based systems

RHEL, CentOS, Rocky Linux, AlmaLinux, Fedora

openSUSE / SUSE Linux Enterprise

Arch Linux / Manjaro

Key Features:

Works on servers and workstations

Auto-detects whether to reboot automatically or prompt the user

Clean and simple CLI arguments — no hardcoded domain or credentials

Creates a log file with full run details for troubleshooting

Supports flexible access control via users and groups (or open access)

Safe for open-source use under the MIT License

Use Case:
Ideal for system administrators, DevOps engineers, and IT teams who manage Linux systems in enterprise environments and need a fast, repeatable, and reliable way to integrate with Microsoft Active Directory.
