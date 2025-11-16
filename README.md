<h1 align="center">🚀 Paymenter Auto-Installer</h1>

<p align="center">
  <b>A clean, secure, professional installation script for Paymenter — optimized for Ubuntu & Debian.</b>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Installer-Paymenter-blue?style=for-the-badge">
  <img src="https://img.shields.io/badge/Shell-Bash-green?style=for-the-badge">
  <img src="https://img.shields.io/badge/License-MIT-yellow?style=for-the-badge">
</p>

---

## ✨ Overview

The **Paymenter Installer** is a fully automated, secure, and production-ready setup tool.  
It configures everything for you — PHP, MariaDB, Redis, cronjobs, queue workers, nginx, SSL, and optional auto-updates — all with clean UI and zero password exposure.

Perfect for hosting panels, billing platforms, production deployments, or rapid testing environments.

---

## 🛠️ Features

- 🧩 **One-command installation**
- 🐧 Supports **Ubuntu 20.04/22.04/24.04** & **Debian 10/11/12**
- ⚡ Installs **PHP 8.3**, extensions, MariaDB 10.11, Redis, nginx
- 🗄️ Automatic database creation
- 🔐 **Passwords NEVER displayed or logged**
- 🔄 Systemd queue worker (`paymenter.service`)
- 🕒 Cron-based scheduler
- 🌐 HTTP or HTTPS (Let's Encrypt) support
- 🔧 Optional auto-update using `php artisan app:upgrade`
- 🧹 Cleanup & permission fixes
- 🎛️ Simple, user-friendly menu interface

---

## ⚡ Quick Install

### 🔧 Run this on a fresh VPS:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/HeyYuvraj/paymenter-script/main/installer.sh)
