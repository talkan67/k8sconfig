.\linux_deploy.ps1 `
  -PublishFolder "C:\Users\talkan\source\repos\talkan67\ORTAK\ORTAK.WEB.UI.ADMIN\bin\Debug\net8.0\publish" `
  -RemoteHost "development.ortaknet.org" `
  -RemoteUser "ubuntu" `
  -RemoteAppDir "/home/ubuntu/ORTAK" `
  -AppServiceName "ortak.service" `
  -RemoteBackupDir "/home/ubuntu/app_backups" `
  -RemoteLogDir "/var/log/ortak-deploy" `
  -SshKeyPath "D:\ortaknet.org\development\openssh_pk"