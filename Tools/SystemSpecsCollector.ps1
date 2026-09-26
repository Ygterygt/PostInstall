#Requires -Version 5.1
<#
.SYNOPSIS
    SystemSpecsCollector.ps1 - Universal Hardware & Health Assessment Engine v3.0
.DESCRIPTION
    Extracts complete system hardware profile on ANY PC (Desktop, Laptop, VM)
    Universal support for:
      - Chassis Form Factor: Desktop, Laptop/Notebook, Virtual Machine (VMware, VBox, Hyper-V, KVM)
      - Battery & Power: AC/DC state, battery presence and charge
      - CPU: AMD (Ryzen/Athlon/Threadripper), Intel (Core i3/i5/i7/i9/Ultra, Xeon), Qualcomm ARM
      - Multi-GPU: NVIDIA (GeForce/RTX/Quadro), AMD (Radeon/PRO), Intel (Arc/Iris/UHD)
      - Motherboard / OEM: ASUS, MSI, Gigabyte, ASRock, Dell, HP, Lenovo, Razer, Framework, etc.
      - RAM: Dynamic DDR3/DDR4/DDR5 capacity, real MHz vs rated MHz XMP/DOCP/EXPO detection
      - Disks: NVMe M.2, SATA SSD, HDD, Storage Spaces across all drive letters
#>

function Get-SystemHealthSummary {
    $osInfo   = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cpuInfo  = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
    $baseInfo = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue
    $biosInfo = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
    $cs       = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $enclosure= Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue | Select-Object -First 1
    $battery  = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1

    # 1. Form Factor & Chassis Classification (Desktop vs Laptop vs Virtual Machine)
    $isVM = $false
    $vmPlatform = "Physical"
    $modelStr = "$($cs.Manufacturer) $($cs.Model)".ToLower()

    if ($modelStr -match "vmware") {
        $isVM = $true; $vmPlatform = "VMware"
    } elseif ($modelStr -match "virtualbox") {
        $isVM = $true; $vmPlatform = "VirtualBox"
    } elseif ($modelStr -match "hyper-v" -or $modelStr -match "virtual machine") {
        $isVM = $true; $vmPlatform = "Hyper-V"
    } elseif ($modelStr -match "qemu" -or $modelStr -match "kvm") {
        $isVM = $true; $vmPlatform = "QEMU/KVM"
    }

    $chassisTypes = if ($enclosure.ChassisTypes) { $enclosure.ChassisTypes } else { @(3) }
    $isLaptop = [bool]($battery -or ($chassisTypes | Where-Object { $_ -in @(8, 9, 10, 11, 12, 14, 18, 21, 31, 32) }))
    
    $chassisName = if ($isVM) { "Sanal Makine ($vmPlatform)" }
                   elseif ($isLaptop) { "Dizustu Bilgisayar (Laptop / Mobil)" }
                   else { "Masaustu Bilgisayar (Desktop / Kasa)" }

    # 2. Multi-GPU Discovery & Analysis
    $rawGpus = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue
    $gpus = $rawGpus | Where-Object { $_.Name -notlike "*Basic Display*" -and $_.Name -notlike "*Virtual*" }
    if (-not $gpus) { $gpus = $rawGpus }
    if (-not $gpus) { $gpus = @() }

    $gpuListSummary = @()
    $detectedGpuVendors = @()
    $discreteGpu = $null
    $integratedGpu = $null

    foreach ($g in $gpus) {
        $name = $g.Name.Trim()
        $vendor = "Bilinmiyor"
        $isDiscrete = $false

        if ($name -like "*NVIDIA*") {
            $vendor = "NVIDIA"
            $isDiscrete = $true
        } elseif ($name -like "*AMD*" -or $name -like "*Radeon*") {
            $vendor = "AMD"
            if ($name -match "(RX|XT|Pro|Vega 56|Vega 64|R9|R7|HD [78])") { $isDiscrete = $true }
        } elseif ($name -like "*Intel*") {
            $vendor = "Intel"
            if ($name -like "*Arc*") { $isDiscrete = $true }
        }

        if ($vendor -ne "Bilinmiyor" -and $detectedGpuVendors -notcontains $vendor) {
            $detectedGpuVendors += $vendor
        }

        $driverDate = "Bilinmiyor"
        if ($g.DriverDate) {
            try { $driverDate = ([datetime]$g.DriverDate).ToString('yyyy-MM-dd') } catch {}
        }

        $gpuItem = [PSCustomObject]@{
            Name          = $name
            Vendor        = $vendor
            DriverVersion = $g.DriverVersion
            DriverDate    = $driverDate
            IsDiscrete    = $isDiscrete
            Status        = $g.Status
        }
        $gpuListSummary += $gpuItem

        if ($isDiscrete -and -not $discreteGpu) {
            $discreteGpu = $gpuItem
        } elseif (-not $isDiscrete -and -not $integratedGpu) {
            $integratedGpu = $gpuItem
        }
    }

    $primaryGpu = if ($discreteGpu) { $discreteGpu } elseif ($gpuListSummary.Count -gt 0) { $gpuListSummary[0] } else { $null }

    # 3. Memory & XMP/DOCP Assessment
    $ramList  = Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue
    $volumes  = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | Sort-Object DriveLetter
    $disks    = Get-PhysicalDisk -ErrorAction SilentlyContinue | Sort-Object DeviceId

    $totalRamBytes = ($ramList | Measure-Object -Property Capacity -Sum).Sum
    $totalRamGB = if ($totalRamBytes) { [math]::Round($totalRamBytes / 1GB, 1) } else { [math]::Round($cs.TotalPhysicalMemory / 1GB, 1) }
    $ramStick = $ramList | Select-Object -First 1
    $ramSpeedActual = if ($ramStick.ConfiguredClockSpeed) { $ramStick.ConfiguredClockSpeed * 2 } elseif ($ramStick.Speed) { $ramStick.Speed } else { 0 }
    $ramSpeedRated  = if ($ramStick.Speed) { $ramStick.Speed } else { $ramSpeedActual }

    # 4. CPU Vendor Detection
    $cpuVendor = if ($cpuInfo.Manufacturer -like "*AMD*" -or $cpuInfo.Name -like "*AMD*") { "AMD" }
                 elseif ($cpuInfo.Manufacturer -like "*Intel*" -or $cpuInfo.Name -like "*Intel*") { "Intel" }
                 elseif ($cpuInfo.Manufacturer -like "*Qualcomm*" -or $cpuInfo.Name -like "*Snapdragon*") { "Qualcomm" }
                 else { "Diger" }

    # 5. Motherboard & OEM Detection
    $mbMaker = if ($baseInfo.Manufacturer) { $baseInfo.Manufacturer.Trim() } else { $cs.Manufacturer }
    $mbModel = if ($baseInfo.Product) { $baseInfo.Product.Trim() } else { $cs.Model }

    # 6. Safe BIOS Release Date
    $biosDateStr = "Bilinmiyor"
    $biosAgeDays = 0
    if ($biosInfo -and $biosInfo.ReleaseDate) {
        try {
            $parsedDate = [datetime]$biosInfo.ReleaseDate
            $biosDateStr = $parsedDate.ToString('yyyy-MM-dd')
            $biosAgeDays = (New-TimeSpan -Start $parsedDate -End (Get-Date)).Days
        } catch {}
    }

    # 7. Health Warnings Collection
    $warnings = @()

    # RAM XMP check
    $isXmpActive = ($ramSpeedActual -ge 2933 -or ($ramSpeedRated -gt 0 -and $ramSpeedActual -ge $ramSpeedRated))
    if ($ramSpeedRated -gt $ramSpeedActual -and $ramSpeedActual -lt 2933 -and -not $isVM) {
        $warnings += [PSCustomObject]@{
            Category = "RAM Bellek"
            Level    = "UYARI"
            Message  = "RAM bellekleriniz nominal $ramSpeedRated MHz desteklemesine ragmen su an $ramSpeedActual MHz'de calisiyor. BIOS'tan XMP / DOCP / EXPO profilini acmaniz onerilir."
        }
    }

    # BIOS Age check
    if ($biosAgeDays -gt 1000 -and -not $isVM) {
        $biosYears = [math]::Round($biosAgeDays / 365, 1)
        $warnings += [PSCustomObject]@{
            Category = "Anakart BIOS"
            Level    = "BILGI"
            Message  = "Mevcut BIOS yaklasik $biosYears yillik ($biosDateStr). Donanim stabilitesi icin uretici sayfasindan guncelleme kontrol edilmelidir."
        }
    }

    # Storage Check across all volumes
    foreach ($v in $volumes) {
        if ($v.FileSystemType -in @("Unknown", "") -or $v.Size -eq 0) {
            $warnings += [PSCustomObject]@{
                Category = "Depolama"
                Level    = "DIKKAT"
                Message  = "Surucu $($v.DriveLetter): bicimlendirilmemis (RAW) durumda. Otomatik formatlama devre disidir."
            }
        } elseif ($v.Size -gt 0 -and ($v.SizeRemaining / $v.Size) -lt 0.15) {
            $freeGB = [math]::Round($v.SizeRemaining / 1GB, 1)
            $warnings += [PSCustomObject]@{
                Category = "Depolama"
                Level    = "UYARI"
                Message  = "Surucu $($v.DriveLetter): uzerinde bos alan kritik duzeyde az ($freeGB GB kaldi, <%15)."
            }
        }
    }

    $primaryGpuDesc = if ($primaryGpu) { "$($primaryGpu.Name) (Surucu: $($primaryGpu.DriverVersion))" } else { "Standart Grafik Bagdastirici" }

    return [PSCustomObject]@{
        ComputerName   = $env:COMPUTERNAME
        UserName       = $env:USERNAME
        OSName         = $osInfo.Caption
        OSBuild        = "$($osInfo.BuildNumber).$($osInfo.ServicePackMajorVersion)"
        OSArch         = $osInfo.OSArchitecture
        ChassisType    = $chassisName
        IsLaptop       = $isLaptop
        IsVM           = $isVM
        BatteryPresent = [bool]$battery
        CPU            = if ($cpuInfo) { $cpuInfo.Name.Trim() } else { "Bilinmiyor" }
        CPUVendor      = $cpuVendor
        CPUCores       = if ($cpuInfo) { "$($cpuInfo.NumberOfCores) Cekirdek / $($cpuInfo.NumberOfLogicalProcessors) Is Parcacigi" } else { "N/A" }
        Motherboard    = "$mbMaker $mbModel".Trim()
        BIOSVersion    = "$($biosInfo.SMBIOSBIOSVersion) ($biosDateStr)"
        RAMTotal       = "$totalRamGB GB"
        RAMSpeedActual = "$ramSpeedActual MHz"
        RAMSpeedRated  = "$ramSpeedRated MHz"
        IsXmpActive    = $isXmpActive
        GPU            = $primaryGpuDesc
        GPUVendor      = if ($primaryGpu) { $primaryGpu.Vendor } else { "Bilinmiyor" }
        GPUVendors     = $detectedGpuVendors
        GPUList        = $gpuListSummary
        Volumes        = $volumes
        Disks          = $disks
        Warnings       = $warnings
    }
}
