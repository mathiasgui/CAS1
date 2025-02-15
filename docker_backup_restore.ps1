# Définir le chemin complet vers docker.exe et docker-compose.exe
$dockerPath = "C:\Program Files\Docker\Docker\resources\bin\docker.exe"
$dockerComposePath = "C:\Program Files\Docker\Docker\resources\bin\docker-compose.exe"

# Définir le dossier de sauvegarde dans le répertoire du script
$scriptPath = $PSScriptRoot
$backupPath = Join-Path $scriptPath "Backup"

# Création du dossier Backup s'il n'existe pas
if (-not (Test-Path $backupPath)) {
    Write-Output "🔄 Le dossier 'Backup' n'existe pas. Création du dossier..."
    New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
}

# Créer les sous-dossiers pour Images, Volumes, Networks et Containers
$imagesBackupDir = Join-Path $backupPath "Images"
$volumesBackupDir = Join-Path $backupPath "Volumes"
$networksBackupDir = Join-Path $backupPath "Networks"
$containersBackupDir = Join-Path $backupPath "Containers"

foreach ($dir in @($imagesBackupDir, $volumesBackupDir, $networksBackupDir, $containersBackupDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

function Backup-Docker {
    Write-Output "📦 Démarrage de la sauvegarde Docker..."

    # 1️⃣ Sauvegarde des images Docker dans Backup\Images
    Write-Output "🔹 Sauvegarde des images Docker..."
    $imagesTarPath = Join-Path $imagesBackupDir "images_backup.tar"
    $imagesIds = & $dockerPath images -q
    if ($imagesIds) {
        & $dockerPath save -o $imagesTarPath $imagesIds
    } else {
        Write-Output "Aucune image trouvée pour la sauvegarde."
    }

    # 2️⃣ Sauvegarde des volumes Docker dans Backup\Volumes
    Write-Output "🔹 Sauvegarde des volumes Docker..."
    $volumes = & $dockerPath volume ls -q
    foreach ($volume in $volumes) {
        $volumeBackupPath = Join-Path $volumesBackupDir "${volume}_backup.tar.gz"
        & $dockerPath run --rm -v "${volume}:/volume" -v "${volumesBackupDir}:/backup" alpine tar czf "/backup/${volume}_backup.tar.gz" -C /volume .
    }

    # 3️⃣ Sauvegarde des conteneurs sous forme d'images dans Backup\Containers
    Write-Output "🔹 Sauvegarde des conteneurs..."
    $containers = & $dockerPath ps -aq
    foreach ($container in $containers) {
        $imageName = "backup_container_$container"
        # Créer une image à partir du conteneur
        & $dockerPath commit $container $imageName
        # Construire le chemin pour sauvegarder l'image du conteneur
        $containerTarPath = Join-Path $containersBackupDir "$imageName.tar"
        & $dockerPath save -o $containerTarPath $imageName
    }

    # 4️⃣ Sauvegarde des réseaux dans Backup\Networks
    Write-Output "🔹 Sauvegarde des réseaux..."
    $networksBackupFile = Join-Path $networksBackupDir "networks_backup.txt"
    & $dockerPath network ls --format "{{.Name}}" > $networksBackupFile

    # 5️⃣ Sauvegarde du fichier docker-compose.yml (s'il existe) dans le dossier Backup
    Write-Output "🔹 Sauvegarde du fichier docker-compose.yml..."
    $dockerComposeFile = Join-Path $scriptPath "docker-compose.yml"
    if (Test-Path $dockerComposeFile) {
        Copy-Item -Path $dockerComposeFile -Destination (Join-Path $backupPath "docker-compose.yml")
    }

    # 6️⃣ Sauvegarde des dossiers supplémentaires (certificates, config, ldif)
    Write-Output "🔹 Sauvegarde des dossiers supplémentaires (certificates, config, ldif)..."
    $foldersToBackup = @("certificates", "config", "ldif")
    foreach ($folder in $foldersToBackup) {
        $sourcePath = Join-Path $scriptPath $folder
        $destPath = Join-Path $backupPath $folder
        if (Test-Path $sourcePath) {
            Copy-Item -Path $sourcePath -Destination $destPath -Recurse -Force
        }
    }

    Write-Output "✅ Sauvegarde terminée ! Fichiers disponibles dans $backupPath"
}

function Restore-Docker {
    Write-Output "🔄 Démarrage de la restauration Docker..."

    # 1️⃣ Restauration des images Docker depuis Backup\Images
    $imagesTarPath = Join-Path $imagesBackupDir "images_backup.tar"
    if (Test-Path $imagesTarPath) {
        Write-Output "🔹 Restauration des images Docker..."
        & $dockerPath load -i $imagesTarPath
    } else {
        Write-Output "⚠ Aucune image Docker sauvegardée trouvée dans Images."
    }

    # 2️⃣ Restauration des volumes Docker depuis Backup\Volumes
    Write-Output "🔹 Restauration des volumes Docker..."
    $volumeBackups = Get-ChildItem -Path $volumesBackupDir -Filter "*_backup.tar.gz"
    foreach ($backup in $volumeBackups) {
        # Supposer que le nom du volume se retrouve dans le nom du fichier
        $volumeName = $backup.BaseName -replace "_backup", ""
        & $dockerPath volume create $volumeName
        & $dockerPath run --rm -v "${volumeName}:/volume" -v "${volumesBackupDir}:/backup" alpine tar xzf "/backup/$($backup.Name)" -C /volume
    }

    # 3️⃣ Restauration des conteneurs depuis Backup\Containers
    Write-Output "🔹 Restauration des conteneurs..."
    $containerBackups = Get-ChildItem -Path $containersBackupDir -Filter "*.tar"
    foreach ($backup in $containerBackups) {
        & $dockerPath load -i $backup.FullName
    }

    # 4️⃣ Restauration des réseaux depuis Backup\Networks
    $networksBackupFile = Join-Path $networksBackupDir "networks_backup.txt"
    if (Test-Path $networksBackupFile) {
        Write-Output "🔹 Restauration des réseaux..."
        $networks = Get-Content $networksBackupFile
        foreach ($network in $networks) {
            if ($network -in @("bridge", "host", "none")) {
                Write-Output "⏩ Réseau '$network' est prédéfini. Passage au suivant."
                continue
            }
            $existing = (& $dockerPath network ls --filter "name=^$network$" --format "{{.Name}}").Trim()
            if ($existing -eq $network) {
                Write-Output "⏩ Réseau '$network' existe déjà. Passage au suivant."
            } else {
                try {
                    & $dockerPath network create $network
                } catch {
                    Write-Output "⚠ Erreur lors de la création du réseau '$network': $_"
                }
            }
        }
    } else {
        Write-Output "⚠ Aucun réseau sauvegardé trouvé."
    }

    # 5️⃣ Restauration du fichier docker-compose.yml
    $composeBackupPath = Join-Path $backupPath "docker-compose.yml"
    if (Test-Path $composeBackupPath) {
        Write-Output "🔹 Restauration du fichier docker-compose.yml..."
        Copy-Item -Path $composeBackupPath -Destination $scriptPath
        Set-Location $scriptPath
        if (Test-Path $dockerComposePath) {
            & $dockerComposePath up -d
        } else {
            Write-Output "⚠ docker-compose.exe introuvable dans le chemin spécifié."
        }
    } else {
        Write-Output "⚠ Aucun fichier docker-compose.yml trouvé."
    }

    # 6️⃣ Restauration des dossiers supplémentaires (certificates, config, ldif)
    Write-Output "🔹 Restauration des dossiers supplémentaires (certificates, config, ldif)..."
    foreach ($folder in @("certificates", "config", "ldif")) {
        $sourcePath = Join-Path $backupPath $folder
        $destPath = Join-Path $scriptPath $folder
        if (Test-Path $sourcePath) {
            Copy-Item -Path $sourcePath -Destination $destPath -Recurse -Force
        }
    }

    Write-Output "✅ Restauration terminée !"
}

# Menu pour l'utilisateur
Write-Output "🎛 MENU - Sauvegarde et restauration Docker"
Write-Output "1️⃣ Sauvegarder Docker (images, volumes, conteneurs, réseaux, docker-compose.yml, et dossiers certificates/config/ldif)"
Write-Output "2️⃣ Restaurer Docker (tout récupérer à partir de la dernière sauvegarde)"
Write-Output "3️⃣ Quitter"
$choice = Read-Host "Choisissez une option (1, 2 ou 3)"

switch ($choice) {
    "1" { Backup-Docker }
    "2" { Restore-Docker }
    default { Write-Output "🚪 Sortie du script." }
}
