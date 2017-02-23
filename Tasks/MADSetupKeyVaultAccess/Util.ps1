function Upload-CertificateToKeyVault {
    param(
        [string]$certificateLocation,
        [securestring]$certificatePassword,
        [string]$vaultName,
        [string]$user,
        [string]$tenantId
    )
    Write-Host "##[command]Adding Azure management to access policy"
    Add-KeyVaultAccessPolicy $tenantId $vaultName "397507d3-5375-43c9-ac83-f537e230e73a"
    
    Write-Host "##[command]Adding $tenantId $user to access policy"
    Set-AzureRmKeyVaultAccessPolicy -VaultName $vaultName -ServicePrincipalName $user -PermissionsToSecrets All
    
    Write-Host "##[command]Uploading $certificateLocation to vault"    
    $flag = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
    $pfx = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
    $pfx.Import($certificateLocation, $certificatePassword, $flag)
    $pcks12ContentType = [System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12
    $clearBytes = $pfx.Export($pcks12ContentType)
    $fileContentEncoded = [System.Convert]::ToBase64String($clearBytes)
    $secret = ConvertTo-SecureString -String $fileContentEncoded -AsPlainText -Force
    $secretContentType = "application/x-pkcs12"

    $result = Set-AzureKeyVaultSecret -VaultName $vaultName -Name keyVaultCert -SecretValue $secret -ContentType $secretContentType
}

function Add-KeyVaultAccessPolicy {
    param(
        [string]$tenantId,
        [string]$vaultName,        
        [string]$objectId
    )
    $vault = Get-AzureRmKeyVault -VaultName $vaultName
    
    $config = Get-AzureRestValue "$($vault.ResourceId)?api-version=2015-06-01"
    $policyAlreadyDefined = $false
    [System.Collections.ArrayList]$access = $config.properties.accessPolicies

    foreach($policy in $access){
        if($policy.objectId -eq $objectId){
            $policyAlreadyDefined = $true
            break            
        }
    }

    if($policyAlreadyDefined){
        Write-Host "##[command]Access already in place"
        return
    }
    Write-Host "Access policy does not exist - adding..."

    $newPolicy = @"
        {
            'tenantId': '$tenantId',
            'objectId': '$objectId',
            'permissions': {
            'keys': [],
            'secrets': [
                'All'
            ],
            'certificates': []
            }
        }
"@
    $jNewPolicy = $newPolicy | ConvertFrom-Json 
    $count = $access.Add($jNewPolicy)
    
    $config.properties.accessPolicies = $access
    $payload = $config | ConvertTo-Json -Depth 10
    $result = Set-AzureRestValue "$($vault.ResourceId)?api-version=2015-06-01" "$payload"
}

function Add-CertificateToWebApp {
    param(
        [string]$resourceGroupName,
        [string]$webApp,
        [string]$vaultName
    )
    
    $app = Get-AzureRmWebApp -Name $webApp
    $vault = Get-AzureRmKeyVault -VaultName $vaultName
    $resourceGroup = Get-AzureRmResourceGroup -Name $resourceGroupName

    $payload = "{
            'Location': '$($resourceGroup.Location)',
            'Properties': {
                'KeyVaultId': '$($vault.ResourceId)',
                'KeyVaultSecretName': 'keyVaultCert',
                'serverFarmId': '$($app.ServerFarmId)'
                }
            }"

    Write-Host "##[command]Configuring $webApp to use certificate"    

    $resource = $resourceGroup.ResourceId + "/providers/Microsoft.Web/certificates/KeyVaultCert?api-version=2016-03-01"
    $result = Set-AzureRestValue $resource "$payload"
}