# csvdiff

a fast commandline diff tool for csv-files written in zig

## functionality

It can either show the difference per line, order in the file does not matter and duplicate lines are also accounterd for, or you can specify key columns to match, which checks if the other columns are matching for matching keys. Colums can also be excluded from the check.

On default only missmatched lines are outputed with a +,-,<,> or ~ sign. The added and mismatched lines are outputed in the order of the 2nd file. All missing lines from the 1st file are outputed at the end without any order.

| sign | meaning                                                                                  |
| ---- | ---------------------------------------------------------------------------------------- |
| -    | the line from the firs file is missing in the 2nd file, i.e. was removed in the 1st file |
| +    | the line is in the 2nd file but not in the 1st file, i.e. was added in the 2nd file      |
| <    | the line from the 1st file was matched by key but the value columns are different        |
| >    | the line from the 2st file was matched by key but the value columns are different        |
| ~    | in columnDiff mode when the key was matched but the value columns are difer              |

## Build requirements
To build csvdiff you just need the zig compiler, which can be downloaded from [https://ziglang.org/download/](https://ziglang.org/download/) 
Currently zig master (0.14.0) is supported, builds might break in never and older versions.
There is no installation needed, just download the package for your operating system an extract the archive and add it to your `PATH`

### Windows example
execute following commands in a windows Command Prompt (cmd.exe)
```cmd
curl https://ziglang.org/builds/zig-windows-x86_64-0.14.0-dev.2851+b074fb7dd.zip --output zig.zip
tar -xf zig.zip
del zig.zip
move zig-windows-x86_64-0.14.0-dev* zig
set PATH=%cd%\zig;%PATH%
```

### Linux example
execute following commands in a shell
```bash
curl zig-linux-x86_64-0.14.0-dev.2851+b074fb7dd.tar.xz --output zig.tar.xz
tar -xf zig.tar.xz
rm zig.tar.xz
mv zig-linux-x86_64-0.14.0-dev* zig
export PATH=$(pwd)/zig:$PATH
```

## Build
If you have zig installed and on your `PATH` just cd into the directory and execute `zig build`
The first build takes a while and when it's finished you'll find the executeable (csvcut or csvcut.exe) in zig-out/bin/
You can run the built-in uinit tests with `zig build test` If everything is ok you will see no output.
Use `zig build -Doption=ReleaseFast` to build a release version optimized for speed.

## Usage
see [src/USAGE.txt](src/USAGE.txt)

## Licence
csvcut is licensed under the MIT license

see [LICENSE.txt](LICENSE.txt)
