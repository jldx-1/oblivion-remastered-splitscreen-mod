# Oblivion Remastered Local Split Screen

An experimental Windows mod for two players on one PC.

![Two side-by-side player views in Talos Plaza, each with its own compass and HUD](docs/media/left-right.webp)

[Project page, demo, and Windows download](https://jldx-1.github.io/oblivion-remastered-splitscreen-mod/docs/index.html)

## Features

- Local co-op for two players on one PC.
- Side-by-side or top-and-bottom views, with a separate HUD and compass for each player.
- In-game controller pairing and character appearance options for Player 2.
- Separate inventories, item pickups, and voiced NPC dialogue for supported topics.
- Co-op revives and respawns.

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

[SHA-256 checksums for the Windows downloads](https://jldx-1.github.io/oblivion-remastered-splitscreen-mod/docs/download/SHA256SUMS.txt)
