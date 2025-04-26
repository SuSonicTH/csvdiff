Output media/csvdiff.gif

Hide
Type@1ms "./build.sh"
Enter
Type@1ms "cd ./bin"
Enter
Type@1ms "cp ../src/test/people.csv ./"
Enter
Type@1ms "cp ../src/test/differentPeople.csv ./"
Enter

Type@1ms "clear"
Enter
Sleep 200ms
Show


Sleep 2s
Type "# simple line diff"
Enter
Sleep 500ms

Type "./csvdiff people.csv differentPeople.csv"
Sleep 500ms
Enter
Sleep 4s

Type@1ms "clear"
Enter
Type "# add some color with the --color argument"
Enter
Sleep 500ms

Type "./csvdiff people.csv differentPeople.csv --color"
Sleep 500ms
Enter
Sleep 4s

Type@1ms "clear"
Enter
Type "# first column as primary key"
Enter
Sleep 500ms

Type "./csvdiff people.csv differentPeople.csv --color --key 1"
Sleep 500ms
Enter
Sleep 4s

Type@1ms "clear"
Enter
Type "# keys can be column names if the file has a header"
Enter
Sleep 500ms

Type "./csvdiff people.csv differentPeople.csv --color --key 'Customer Id'"
Sleep 500ms
Enter
Sleep 4s

Type@1ms "clear"
Sleep 150ms
Enter
Type "# output also matching lines with --outputAll"
Enter
Sleep 500ms

Type "./csvdiff people.csv differentPeople.csv --color --key 1 --outputAll"
Sleep 500ms
Enter
Sleep 4s


Type@1ms "clear"
Sleep 150ms
Enter
Type "# show diff of value columns inline separated by '|'"
Enter
Sleep 500ms

Type "./csvdiff people.csv differentPeople.csv --color --key 1 --fieldDiff"
Sleep 500ms
Enter
Sleep 4s


Type@1ms "clear"
Sleep 150ms
Enter
Type "# output as csv with header for processing in other tools with --asCsv"
Enter
Sleep 500ms

Type "./csvdiff people.csv differentPeople.csv --asCsv --outputAll"
Sleep 500ms
Enter
Sleep 4s


Hide
Type@1ms "rm people.csv"
Enter
Type@1ms "rm differentPeople.csv"
Enter
