# Oblivion Remastered Local Split Screen

An experimental Windows mod for two players on one PC.

![Two side-by-side player views in Talos Plaza, each with its own compass and HUD](docs/media/left-right.webp)

[Project page, demo, and Windows download](https://jldx-1.github.io/oblivion-remastered-splitscreen-mod/docs/index.html)

## Install from the ZIP on Windows

Use the Windows version of Oblivion Remastered from Steam. The installer checks compatibility before copying files. For Player 2’s voiced conversations, separate inventory, and supported hotel travel, install [stock OBSE64 from its author](https://www.nexusmods.com/oblivionremastered/mods/282). Follow its instructions to put the loader and runtime beside the game executable in `OblivionRemastered\Binaries\Win64`. The mod download includes the split-screen plugin.

1. Close Oblivion Remastered and [download the Windows ZIP](https://jldx-1.github.io/oblivion-remastered-splitscreen-mod/docs/download/LocalSplitScreen-Windows.zip).
2. In File Explorer, right-click the ZIP and select **Extract All**. Open the extracted folder. It should contain **Install.ps1** and a **payload** folder. Keep them together. The installer uses the payload to place UE4SS, the OBSE64 plugin, and the mod files in the game's `OblivionRemastered\Binaries\Win64` folder.
3. Open **Windows PowerShell** as administrator. In File Explorer, copy the path of the extracted folder from the address bar. Paste it into the first command below, replacing the example path, then run both commands.

   ```powershell
   Set-Location -LiteralPath "<paste the extracted folder path here>"
   powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Install.ps1
   ```

   If PowerShell blocks the downloaded script, run `Unblock-File -LiteralPath .\Install.ps1` from the extracted folder and retry.
4. If a folder picker opens, select the top-level **Oblivion Remastered** installation folder. To find it in Steam, right-click the game and choose **Manage → Browse local files**. You can also pass the folder explicitly with `-GameDirectory`.

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\Install.ps1 -GameDirectory "<paste the Steam game folder path here>"
   ```

5. After PowerShell prints **Installed Local Split Screen**, start Steam, run `obse64_loader.exe` from the game’s `Win64` folder, and load a spare save. With both controllers connected, open **System → Save & Load → Split Screen**. Choose a layout and press **Options** on Player 2’s controller to start.

## Player 2 interactions

Aim at an object and press **Square** on Player 2’s controller. Supported loose items show **Take** and go into Player 2’s inventory.

When either player dies, their pane dims and shows a 30-second revive countdown. The surviving player can approach and hold **Square** for 10 seconds to revive them. The downed player can press **Cross** to respawn immediately, or wait for the countdown to expire. Player 2 can respawn beside Player 1 outside the Tiber Septim Hotel with their equipment and inventory intact.

With OBSE64 running, Player 2 can enter and leave the Tiber Septim Hotel through its front door while Player 1 remains outside in Talos Plaza. Leave the doorway clear when Player 2 returns outside. Aim at a nearby NPC and press **Square** to open Player 2’s dialogue pane with voiced responses for supported topics. Quest-changing dialogue and independent travel through other loading doors are still in development.

If you see a message that a feature is unavailable in this launch, make sure you started with `obse64_loader.exe` and that `OBSE\Plugins\LocalSplitScreenBackend.dll` is present under the game’s `Win64` folder.

To build the standalone OBSE64 plugin from source with Visual Studio Build Tools and CMake:

```powershell
cmake -S src/backend/plugin -B build-obse-plugin -A x64
cmake --build build-obse-plugin --config Release
```

[SHA-256 checksums for the Windows downloads](https://jldx-1.github.io/oblivion-remastered-splitscreen-mod/docs/download/SHA256SUMS.txt)
