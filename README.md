# csvdiff

a fast commandline diff tool for csv-files written in zig

![csvdiff demo](media/csvdiff.gif)

## Functionality

It can either show the difference per line, order in the file does not matter and duplicate lines are also accounterd for, or you can specify key columns to match, which checks if the other columns are matching for matching keys. Colums can also be excluded from the check.

On default only missmatched lines are outputed with a +,-,<,> or ~ sign. Matched lines can be outputted as well with --outputAll and they are prefixed with '='. The added and mismatched lines are outputed in the order of the 2nd file. All missing lines from the 1st file are outputed at the end, their order is not guaranteed.

Headers are compared separately: when both files have a header, differing headers are not reported as data rows. Use `--listHeader` to inspect the parsed header.

Exit codes: `0` means no differences, `1` means the files are different and values greater than `1` are errors. Run `csvdiff --exitCodes` for the full list.

| sign | meaning                                                                                     |
| ---- | ------------------------------------------------------------------------------------------- |
| =    | the lines are equal in first and 2nd file (only written with --outputAll)                   |
| -    | the line from the first file is missing in the 2nd file, i.e. was removed from the 2nd file |
| +    | the line is in the 2nd file but not in the 1st file, i.e. was added to the 2nd file         |
| <    | the line from the 1st file was matched by key but the value columns are different           |
| >    | the line from the 2nd file was matched by key but the value columns are different           |
| ~    | in --fieldDiff mode when the key was matched but the value columns are difer               |

## Build requirements
To build csvdiff you just need the zig compiler, which can be downloaded from [https://ziglang.org/download/](https://ziglang.org/download/) 
Currently [zig](https://ziglang.org) 0.17.0 is supported, builds might break in newer versions and will not work in older versions.
There is no installation needed, just download the package for your operating system an extract the archive and add it to your `PATH`

### Windows example
execute following commands in a windows Command Prompt (cmd.exe)
```cmd
curl https://ziglang.org/download/0.17.0/zig-x86_64-windows-0.17.0.zip --output zig-x86_64-windows-0.17.0.zip
tar -xf zig-x86_64-windows-0.17.0.zip
del zig-x86_64-windows-0.17.0.zip
move zig-x86_64-windows-0.17.0 zig
set PATH=%cd%\zig;%PATH%
```

### Linux example
execute following commands in a shell
```bash
wget https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz
tar -xf zig-x86_64-linux-0.17.0.tar.xz
rm zig-x86_64-linux-0.17.0.tar.xz
mv zig-x86_64-linux-0.17.0 zig
export PATH=$(pwd)/zig:$PATH
```

## Build
If you have zig 0.17.0 installed and on your `PATH` just cd into the directory and execute
```shell
zig build release
```
This builds compressed release binaries for all supported platforms and saves them to `zig-out/bin`:
- `csvdiff-x86_64-linux`
- `csvdiff-aarch64-linux`
- `csvdiff-x86_64-windows.exe`

For a compressed release build for just your native platform use `zig build native`, which saves the executable as `zig-out/bin/csvdiff`.

To run the tests use
```shell
zig build test
```

## Usage
execute `csvdiff --help` to ouput the usage information or see [src/USAGE.txt](src/USAGE.txt)

## Licence
csvdiff is licensed under the MIT license

execute `csvdiff --version` or check [LICENSE.txt](LICENSE.txt) to read it
