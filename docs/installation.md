# Install Astra and set up Windows

## Requirements and availability

Use an Apple Silicon Mac with macOS 14 or newer. Bring your own Windows 11 **ARM64** ISO and valid Windows license; an Intel/x64 installation ISO is unsuitable for this VM. Obtain Windows media directly from [Microsoft](https://www.microsoft.com/software-download/windows11arm64).

This repository is a source preview. It does not include an app installer or the private binary runtime kit. The current complete app was tested locally and is ad hoc signed, not notarized. A public downloadable installer and another-Mac qualification are pending. There is no one-command install from this repository alone.

If you already have a trusted accepted `Astra Parallel.app`, copy the entire app bundle to Applications, preferably through its ZIP archive so framework symlinks survive. Running that complete app needs no installed UTM, Homebrew, Python, or Xcode. Keep macOS security protections enabled; follow the system's normal approval process only for a build whose origin you trust.

## Create Windows

1. Open Astra and choose **New Windows VM…**.
2. Select a Windows 11 ARM64 ISO and a local folder for the new `.astravm` machine. Avoid cloud-synced folders for actively running VMs.
3. Choose CPU, memory, and virtual disk capacity. Leave resources for macOS and enough real free storage for Windows. A sparse disk's advertised capacity is not reserved physical space.
4. Select **Create and Start**. Press a key promptly if the ISO displays the CD/DVD boot prompt.
5. Complete Windows' normal setup, license, and account choices yourself.
6. If Setup asks for a network driver, browse the attached **Astra Guest Tools** disc to `Drivers/Network`.

The wizard creates a new UUID and separate disk, firmware variables, and TPM state. Keep those files together when backing up or moving a machine. **Open Existing VM…** can select another existing `.astravm` folder.

## Install guest tools

After reaching the Windows desktop, choose **VM Tools → Install Astra Guest Tools…**, then open File Explorer → This PC → **Astra Guest Tools**. Double-click **Install Astra Tools.cmd**, approve the normal administrator prompt, and restart Windows after installation. If the installer requires a restart before finishing the display binding, restart and run it again.

The installer source verifies the payload hashes and signed base drivers, installs display/network/serial drivers and guest services, and selects the recorded graphics implementation. Do not disable Windows driver signing, Secure Boot, or other security protections. The complete fresh-install path still needs acceptance testing.

Choose **VM Tools → Eject Windows Installer** after Windows installation so the ISO is not required at startup. Install applications and games through their ordinary installers.

## Daily use

Use **Shut Down** for normal shutdown. Astra reports a timeout if Windows fails to stop. **Power Off…** is a separately confirmed recovery action for an unresponsive or uninstalled guest; it can interrupt writes.

Use Command–Shift–M for game mouse capture and Control–Option to release it. Switching away also releases capture. Audio controls include volume, mute, and background mute. Text clipboard sharing is off by default, enabled per VM, and active only while Astra is in front. Images and files are not transferred.

Check **VM Status…** for separate engine, display, desktop-integration, and guest-control health. Change CPU/RAM/name in **VM Settings…** while stopped.

Before treating a new installation as accepted, check restart after graceful shutdown, drivers and network, audible audio, mouse capture and release, text clipboard in both directions, stopped resource changes, and the applications you intend to run. See [STATUS.md](../STATUS.md) for what has already been verified.
