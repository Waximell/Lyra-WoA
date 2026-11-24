# Lyra Viewer — MSIX 打包

自用 Windows on ARM 安装包。MSIX 只是给同一个 arm64 松散包套了个壳：`dotnet publish`
的输出原样进包，另加清单、图标资源和 `resources.pri`。

## 安装

```powershell
# 1. 信任自签证书（只需一次）
Import-Certificate -FilePath .\waximell-selfsigned.cer -CertStoreLocation Cert:\CurrentUser\TrustedPeople

# 2. 安装
Add-AppxPackage -Path .\LyraViewer-windows-arm64.msix
```

如果第 2 步报「证书链…不受信任」，再把同一张证书导入受信任的根存储（仍不需要管理员）：

```powershell
Import-Certificate -FilePath .\waximell-selfsigned.cer -CertStoreLocation Cert:\CurrentUser\Root
```

证书信息（与 PixEz 的 MSIX 共用同一张自签证书，系统里信任一次即可）：

| 项 | 值 |
|---|---|
| Subject | `CN=Waximell, C=CN` |
| 指纹 | `B1C5C4F56505E5F910FCEB32BC77E2E20C7EDBEB` |
| 有效期至 | 2036-11-17 |

私钥（`.pfx`）不在仓库里，签名密码只存在仓库 Secrets（`MSIX_PFX_BASE64` / `MSIX_PFX_PASSWORD`）。

## 文件关联

清单里声明了这些扩展名，装好后 Lyra 会出现在「打开方式」列表里：

- PNG 家族：`.png` `.apng`
- JPEG 家族：`.jpg` `.jpeg` `.jpe` `.jfif`
- 其他：`.gif` `.webp` `.avif` `.heic` `.heif` `.svg` `.bmp` `.ico`

**应用不能把自己设成默认程序**（Windows 11 的限制，与是否 MSIX 无关）。要双击直接开 Lyra：

> 设置 → 应用 → 默认应用 → 按文件类型选择默认值 → 把 `.png` 等改成 Lyra Viewer

首次双击某类图片会弹「你要如何打开这个文件？」，选一次 Lyra 即可。

## 卸载

```powershell
Get-AppxPackage *LyraViewer* | Remove-AppxPackage
```

文件关联会随包一起清掉，不留注册表垃圾。

## 重新打包

CI 的 `msix` job 会跑：

```powershell
./ci/build-msix.ps1 -PublishDir out/publish -OutFile out/LyraViewer-windows-arm64.msix `
    -CertPath signing.pfx -CertPassword $env:PFX_PASSWORD -Version 0.6.0.0
```

本地跑需要 Windows SDK（`makeappx` / `makepri` / `signtool`）。打包**不需要** ARM64 机器，
架构是写在清单里的。
