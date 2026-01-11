# swa
**Interactive context-switching tool for AWS CLI and other S3-compatible clients on Windows and Linux shells.**


## Windows (Batch-Script)

In Windows, ensure dependencies are installed and simply place `swa.cmd` in PATH to use it. (recommended location: `%USERPROFILE%\AppData\Local\bin`).

```batch
mkdir %USERPROFILE%\AppData\Local\bin
git clone https://github.com/bruckware/swa.git
copy swa\swa.cmd "%USERPROFILE%\AppData\Local\bin\"
:: Add "%USERPROFILE%\AppData\Local\bin" to the PATH and restart running shell
swa --version
```


## Linux (Bash-Script)
After ensuring about dependencies and copying `swa.sh` to your filesystem (recommended location: `~/.local/bin`), define a shell function that invokes `swa.sh` using `eval`. This causes the script to run in a child process, and upon completion, only the required AWS environment variables are exported into the current shell session.

```bash
mkdir -p ~/.local/bin
git clone https://github.com/bruckware/swa.git
cp swa/swa.sh ~/.local/bin/swa.sh
chmod +x ~/.local/bin/swa.sh

cat >> ~/.bashrc <<'EOF'
swa() {
    local out
    out="$("$HOME/.local/bin/swa.sh" "$@")" || return
    eval "$out"
}
EOF

source ~/.bashrc
swa --version
```


## Dependencies
  - [aws](https://github.com/aws/aws-cli) → version ≥ 2.30.3
  - [gum](https://github.com/charmbracelet/gum) → gum (Charmbracelet) for select prompts.
  - [curl](https://curl.se/docs/releases.html) → included in Windows 10 (build ≥ 17063). If `curl` does not exist at  `%SystemRoot%\System32\curl.exe`, install it via Chocolatey or Scoop package manager and update `CURL_EXE` variable in `swa.cmd`.
#### Optional
   - [mc](https://github.com/minio/mc) → to use -i option of MinIO client



## Notes
- `swa` does NOT modify the config file to switch profile. 
  - only change that is made to the config file is  when it is detemined a profile requires ca_bundle, path of newly downloaded ca_bundle is added using `aws configure set`.

- `swa` does NOT modify system-wide or user-wide variables table. Environment variables are only exported in the current shell session.
- `swa` does NOT execute destructive commands (e.g., delete) and does not require Administrator or root privileges. It only requires the following permissions:

  - Read access to AWS config file and, AWS credentials file (if present) from default paths or user-defined paths via environment variables

  - Write access to AWS config directory (for caching, runtime executables, and certificates if required by the endpoint)

  - Permission to create or update config files for of `s3cmd` and `mc (MinIO)` in their default locations.

  - Once you are certain that all requirements are already in place, you can comment out some of the checks in the requirements step. This avoids rechecking them every time you run `swa` on the same system and helps speed up the script startup (for example, config and credentials file checks or tool availability checks).

#### Windows specific
- `EnableExtensions` is enabled by default on Windows (since NT 4.0).
If it has been explicitly disabled on your system, it must be enabled before running `swa`.

- ANSI escape sequences are used and a terminal that supports ANSI escape sequences is required. Native terminals of Windows 10 (build ≥ 10586) support ANSI escape sequences by default.

