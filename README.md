# dotenvman

Read, Write, and Manage .env files in a POSIX-compliant way, \
and preserve comments!

```sh
# read
dotenvman -f ./local.env get ACME_API_TOKEN

# write
dotenvman -f ./local.env set ACME_API_TOKEN='abc$123#'
```

## Table of Contents

- Install
- Usage
  - Setting & Reading Literals
  - Quoting Variables
  - Echoing Variables
- FAQ
  - How to **Escape Single Quotes**
  - How to **Escape Backslashes**

## Install

TODO.

(it's still being written)

## Usage

```sh
dotenvman get <NAME>              # literal
dotenvman set <NAME> <value>      # single-quoted

dotenvman getx <NAME>             # evaluated
dotenvman setx <NAME> <value>     # double-quoted

dotenvman -f <envfile> run <cmd>  # load ENVs and run
```

Global options

```sh
-f, --file=  # path to envfile
```

**ProTips**™:
- use `ALL_CAPS` for keys
- stick to `get` and `set` (for literals - since variables)
- use **single quotes** for values
- use `'\''` to put a single quote in a single-quoted value

### Set & Get Literal Values

`get` and `set` access literal (single-quoted) values \
(this is usually intuitive)

```sh
dotenvman set API_USER='bob'
dotenvman get API_USER
# bob
```

```sh
dotenvman set API_KEY='abc$123'
dotenvman get API_KEY
# abc$123
```

### Set Expressions (Variables)

`setx` will _double quote_ the value as a variable (`$FOO_BAR`) \
(instead of single quoting it as a literal)

Here it will write `API_USER="$USER"` into `.env`:

```sh
dotenvman setx API_USER='$USER'
```

note: you must _set_ the variable with single quotes \
(because that's how your shell works)

### Get Expressions (Variables)


`getx` will _eval_ and **_echo_**, just as your shell would.

Here it will evaluate `"$USER"`, in the current environment, \
and output the value it contains - such as `bob`.

```sh
dotenvman getx API_USER
```

However, `get` will output the string contents, `"$USER"`.

```sh
dotenvman get API_USER
```

Rather than use `getx`, you could also evaluate the output in your shell:

```sh
eval echo "$(dotenvman get API_USER)"
```

## FAQ

### How to Escape a Single Quote?

Let's say you want to put an MOTD banner in an ENV:

```text
Welcome to Ron's Steakhouse!
```

1. You can let `dotenvman` do the work for you:
   ```sh
   cat banner.txt | dotenvman set BANNER_MESSAGE
   ```
   OR
2. You can replace single quotes with `'\''` on your own:
   ```sh
   dotenvman set BANNER_MESSAGE='Welcome to Ron'\''s Steakhouse!'
   ```

**For the curious**: `'\''` works because
1. The first single quote `'` _ends_ the literal mode \
   (then reading continues until a quote or whitespace is found)
2. The escaped quote `\'` allows the string to capture the literal `'` \
   (and reading continues, because this doesn't count as a quote)
3. The next single quote resumes the string, back in literal mode \
   (and reading continues until an ending `'`)

Note: those familiar with shell scripting will know several other ways to escape strings, but this is the simplest, _most silver_ bullet.

## How to Escape a Backslash?

Well, it depends...

Since you're _already_ using this from a shell, you face [the "double escape" problem](https://xkcd.com/1638/):

![](https://imgs.xkcd.com/comics/backslashes_2x.png)

```sh
dotenvman setx SLASHED="This is a \\\\ backslash"
dotenvman get SLASHED
# "This is a \\ backslash"
dotenvman getx SLASHED
# This is a \ backslash
```

## What are the POSIX Escaping Rules?

In short:
- single-quoted values are _perfectly literal_ \
  (not even single quotes `'` can be escaped)
- double-quoted values may have spaces and newlines \
  (`$`, `"`, `` ` ``, and `\` _must_ be escaped)
- unquoted values are similar to double quoted, but terminated by whitespace
