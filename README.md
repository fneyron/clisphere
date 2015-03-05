# clisphere

Ce programme permet de créer des Machines virtuelles Linux avec des interfaces préconfigurés rendant la machine accessible directement une fois déployé. 
Ainsi, on peut directement enchainer le déploiement avec un outils de déploiement automatisé comme Ansible. Le script a été développé en PowerShell, langage qui ressemble beaucoup au Bash.

## Utilisation

Pour l'utiliser il faut commencer par créer un fichier CSV:

    Name;Template;Custom;Cluster;RessourcePool;Folder;Datastore;IP;Netmask; Gateway; VLAN; VCPU; Mem;Disk
    Test1;Template Ubuntu Server 14.04 LTS;PowerCLI-Ubuntu-14.04;Cluster1;Production/Webserver_ressourcepool;Production/Webserver;;192.168.0.5;255.255.255.0;192.168.0.1;VLANID;2;8192;400
Qu'on enregistre sous le nom de vms.csv dans le même dossier que notre script PowerShell.

## Déploiement de VMs
Il faut lancer le script avec en paramètre l'adresse du server ESX et le fichier csv en paramètres:
    
    DeployVMs.ps1 myesx.com vms.csv
Il suffit alors de suivre les étapes du script.

## Supression de VMs
    DeleteVMs.ps1 myesx.com vms.csv
