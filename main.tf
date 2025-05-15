locals {
  admin_user           = "azureuser"
  db_database          = "my_db"
  db_admin_username    = "admin"
  db_admin_password    = "secret"
  local_web_directory  = "${path.module}/web"
  remote_web_directory = "/home/${local.admin_user}/web"
}

resource "azurerm_resource_group" "rg" {
  name     = "my_resource_group"
  location = "East US"
}

resource "azurerm_virtual_network" "vnet" {
  name                = "my_vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "subnet" {
  name                 = "my_subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_public_ip" "pi" {
  name                    = "public-ip"
  location                = azurerm_resource_group.rg.location
  resource_group_name     = azurerm_resource_group.rg.name
  allocation_method       = "Static"
  idle_timeout_in_minutes = 4
}

resource "azurerm_network_interface" "nic" {
  name                = "my_nic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.pi.id
  }
}

resource "azurerm_network_security_group" "nsg" {
  name                = "my_nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "AllowSSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowHTTP"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface_security_group_association" "nic_nsg" {
  network_interface_id      = azurerm_network_interface.nic.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

resource "azurerm_linux_virtual_machine" "vm" {
  name                = "my-web"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  size                = "Standard_B2s"
  admin_username      = local.admin_user
  network_interface_ids = [
    azurerm_network_interface.nic.id,
  ]

  admin_ssh_key {
    username   = "azureuser"
    public_key = file(var.public_key_path)
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  custom_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    db_database : local.db_database
    db_admin_username : local.db_admin_username,
    db_admin_password : local.db_admin_password
  }))
}

resource "null_resource" "build_web" {
  provisioner "local-exec" {
    command = templatefile("${path.module}/build_web.sh.tftpl", {
      web_directory : local.local_web_directory
    })
    working_dir = path.module
  }
}

resource "null_resource" "run_webs" {
  depends_on = [null_resource.build_web, azurerm_linux_virtual_machine.vm]

  connection {
    type        = "ssh"
    user        = local.admin_user
    host        = azurerm_public_ip.pi.ip_address
    private_key = file(var.private_key_path)
  }

  provisioner "remote-exec" {
    inline = [
      "#!/bin/bash",

      # Update
      "sudo apt update",
      "rm -rf web",
      "mkdir web"
    ]
  }

  provisioner "file" {
    source      = "${local.local_web_directory}/.next"
    destination = local.remote_web_directory
  }

  provisioner "file" {
    source      = "${local.local_web_directory}/package.json"
    destination = "${local.remote_web_directory}/package.json"
  }

  provisioner "file" {
    source      = "${local.local_web_directory}/next.config.ts"
    destination = "${local.remote_web_directory}/next.config.ts"
  }

  provisioner "remote-exec" {
    inline = [
      "#!/bin/bash",

      # Install nodejs
      "sudo apt install -y nodejs",
      "sudo apt install -y npm",

      # Install pm2 and stop process if exists
      "sudo npm install -g pm2",
      "pm2 delete 'my-web'",

      # Add environment variables
      "cd web",
      "echo 'DB_HOST=localhost' >> .env",
      "echo 'DB_USER=${local.db_admin_username}' >> .env",
      "echo 'DB_PASSWORD=${local.db_admin_password}' >> .env",
      "echo 'DB_DATABASE=${local.db_database}' >> .env",
      "echo 'BACKEND_URL=http://localhost:3000' >> .env",

      # Build and run web
      "npm install --force",
      "pm2 start --name 'my-web' npm -- start"
    ]
  }
}

resource "null_resource" "clean" {
  depends_on = [null_resource.run_webs]

  provisioner "local-exec" {
    command = "rm -rf ${local.local_web_directory}"
  }
}

resource "azurerm_recovery_services_vault" "vault" {
  name                = "demo-vault"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Standard"
  soft_delete_enabled = false
}

resource "azurerm_backup_policy_vm" "policy" {
  name                = "demo-policy"
  resource_group_name = azurerm_resource_group.rg.name
  recovery_vault_name = azurerm_recovery_services_vault.vault.name

  timezone = "UTC"

  backup {
    frequency = "Daily"
    time      = "23:00"
  }

  retention_daily {
    count = 7
  }
}

resource "azurerm_backup_protected_vm" "vm_backup" {
  resource_group_name = azurerm_resource_group.rg.name
  recovery_vault_name = azurerm_recovery_services_vault.vault.name
  source_vm_id        = azurerm_linux_virtual_machine.vm.id
  backup_policy_id    = azurerm_backup_policy_vm.policy.id
}

resource "azurerm_storage_account" "staging" {
  name                     = var.storage_account
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

output "public_ip_address" {
  value = azurerm_public_ip.pi.ip_address
}
