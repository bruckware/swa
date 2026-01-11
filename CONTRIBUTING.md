## Coding Conventions

First of all, thank you for your interest in contributing to this project!
Your time and effort are greatly appreciated.

To help keep the codebase consistent and maintainable, please follow the coding conventions outlined below.

### Windows (Batch-Script)

- Do NOT use historic and screaming syntax of batch files that used all capital letters.
- Use [snake_case](https://en.wikipedia.org/wiki/Snake_case) almost all the time. Exception applies only to some variable names where capital letters can be used e.g. prefixed with `SWA_`, filenames, color variables.
- Try to keep it pure `batch` (e.g. don't invoke PowerShell command unless it can not be done in `batch`).
- Use `batch` built-in as much as possible, then Windows native tools and finally, other external tools.
- Define Windows native tool path as variable and for other external tools, if they have default path on all Windows versions, define it as variable.
- Avoid long lines and split them to fit body and look of the original code.
- Try to avoid piping and when possible, separate them in different steps for better error handling.
- Try to avoid delete/erase command. If you still need to use such commands, first check with `if exist` then invoke del.
- Use on-liners to avoid paranthesis when possible.
- Always escape paranthesis and other special characters with caret if used in echo command.
- For new info and error messages, add new labels to the end of script and call them where necessary.
- Use quotes almost all the time

### Linux (Bash-Script)
 - Use [snake_case](https://en.wikipedia.org/wiki/Snake_case) almost all the time. Exception applies only to some variable names where capital letters can be used e.g. prefixed with `SWA_`, filenames, color variables.
 - Use `bash` built-in and avoid invoking external binaries as much as possible.
 - Do not use `echo` at all. Use `printf` instead. 
 - To print messages for user, you need to use `print_msg` function which sends message to stderr because `swa` is invoked with `eval`.
 - Use on-liners when possible.
 - Use quotes almost all the time