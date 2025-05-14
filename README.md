# csvdiff

a fast commandline diff tool for csv-files written in zig

![csvdiff demo](media/csvdiff.gif)

## Functionality

It can either show the difference per line, order in the file does not matter and duplicate lines are also accounterd for, or you can specify key columns to match, which checks if the other columns are matching for matching keys. Colums can also be excluded from the check.

On default only missmatched lines are outputed with a +,-,<,> or ~ sign. Matched lines can be outputted as well with --outputAll and they are prefixed with '='. The added and mismatched lines are outputed in the order of the 2nd file. All missing lines from the 1st file are outputed at the end without any order.

| sign | meaning                                                                                     |
| ---- | ------------------------------------------------------------------------------------------- |
| =    | the lines are equal in first and 2nd file (only written with --outputAll)                   |
| -    | the line from the first file is missing in the 2nd file, i.e. was removed from the 2nd file |
| +    | the line is in the 2nd file but not in the 1st file, i.e. was added to the 2nd file         |
| <    | the line from the 1st file was matched by key but the value columns are different           |
| >    | the line from the 2nd file was matched by key but the value columns are different           |
| ~    | in --columnDiff mode when the key was matched but the value columns are difer               |

## Build requirements
To build csvdiff you just need the zig compiler, which can be downloaded from [https://ziglang.org/download/](https://ziglang.org/download/) 
Currently [zig](https://ziglang.org) 0.14.0 is supported, builds might break in never and will not work in older versions.
There is no installation needed, just download the package for your operating system an extract the archive and add it to your `PATH`

### Windows example
execute following commands in a windows Command Prompt (cmd.exe)
```cmd
curl https://ziglang.org/download/0.14.0/zig-windows-x86_64-0.14.0.zip --output zig-windows-x86_64-0.14.0.zip
tar -xf zig-windows-x86_64-0.14.0.zip
del zig-windows-x86_64-0.14.0.zip
move zig-windows-x86_64-0.14.0.zip zig
set PATH=%cd%\zig;%PATH%
```

### Linux example
execute following commands in a shell
```bash
wget https://ziglang.org/download/0.14.0/zig-linux-x86_64-0.14.0.tar.xz
tar -xf zig-linux-x86_64-0.14.0.tar.xz
rm zig-linux-x86_64-0.14.0.tar.xz
mv zig-linux-x86_64-0.14.0 zig
export PATH=$(pwd)/zig:$PATH
```

## Build
If you have zig 0.14.0 installed and on your `PATH` just cd into the directory and execute `./build.sh --test`
This runs the release build and all tests and saves the executable as `./bin/csvdiff`

The build.sh script needs bash, if you don't have bash you can execute the following
```shell
zig build -Doptimize=ReleaseFast
zig test src/main.zig
```

## Usage
execute `csvdiff --help` to ouput the usage information or see [src/USAGE.txt](src/USAGE.txt)

## Licence
csvcut is licensed under the MIT license

execute `csvdiff --version` or check [LICENSE.txt](LICENSE.txt) to read it
