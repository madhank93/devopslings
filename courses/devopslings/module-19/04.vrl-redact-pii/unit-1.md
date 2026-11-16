---
title: "Customer emails are in the support logs, and the first redaction ate the order ids"
---

## The situation

Support's logs go to a store that half the company can read, and they are
full of customer email addresses. Legal wants them gone before the logs
leave the host. Someone wrote a redaction in VRL, Vector's transform
language, in `/obs/vector/redact.vrl`:

```
.message = replace(string!(.message), r'\S+@\S+', "[REDACTED]")
```

It has two problems. The emails are not only in `.message`. And support finds
everything by order reference, which looks like `ord-48213@eu-west-1` (the
order, routed to a region). That regex replaces those too.

`/obs/vector/support.ndjson` is a sample of the events. Run the program over
it and read what comes out:

```
vector vrl -i /obs/vector/support.ndjson -p /obs/vector/redact.vrl -o
```

`-o` prints each event after the program has run. Without `-i`, `vector vrl`
is a REPL where you can try expressions one at a time.

## What an email looks like, and what only contains an @

An address has a local part, an `@`, and a domain made of dot-separated
labels that ends in letters: `jane.doe+promo@mail.example.co.uk`. These
strings contain an `@` and are not addresses:

- `ord-48213@eu-west-1`: the domain part has no dot
- `release@2024.11`: it ends in digits
- `@doe_support`: there is no local part

Text around an address belongs to the text, not to the address. That
includes the comma after it, the angle brackets in `Jane <jane@…>`, and the
`?email=` and `&list=` around it in a URL.

## VRL in brief

- `.field` reads a field, and `.a.b` a nested one. `.` is the whole event.
- `replace(value, r'regex', "with")` replaces every match.
- `string!(x)` asserts that `x` is a string and fails the event if it is not.
  The `!` means "this can fail". VRL refuses to compile a program that
  ignores a possible failure.
- `map_values(value, recursive: true) -> |v| { … }` runs the block on every
  value inside an object or array, however deeply nested, and returns the
  rebuilt structure.
- `is_string(v)` tests a type.

In a real pipeline, this program goes in a `remap` transform with
`file: /obs/vector/redact.vrl`.

## Your objectives

Rewrite `/obs/vector/redact.vrl` so that every customer email address in an
event, wherever it is, is replaced with `[REDACTED]`, and nothing else in the
event changes.

## What you're being graded on

The check runs your program over 300 freshly generated support events and
compares every field of every event with the input:

- no email address is left anywhere, in free text, nested objects or lists
- each address is replaced by exactly `[REDACTED]`, and the rest of the
  string is unchanged
- every field is still there with the same type, including the one that held
  only an email
- order references, release tags and handles come through untouched
- the program does not fail on any event

<details>
<summary>Hint 1 — every field</summary>

Rather than naming each field that might hold an email, walk all of them:
`. = map_values(., recursive: true) -> |v| { … }`. Return `v` unchanged when
it is not a string.

</details>

<details>
<summary>Hint 2 — the regex</summary>

Build it from the description above: a run of the characters a local part
may contain, `@`, one or more `label.` groups, and a final run of letters.
Allow capitals.

</details>

<details>
<summary>Solution</summary>

```
. = map_values(., recursive: true) -> |value| {
  if is_string(value) {
    replace(string!(value), r'[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}', "[REDACTED]")
  } else {
    value
  }
}
```

The domain has to end in `.` and two or more letters. That one requirement
is what separates `jane@example.com` from `ord-48213@eu-west-1` and
`release@2024.11`. The local part's character class has no `<`, `=` or
space in it, so the brackets and the URL around an address stay where they
were.

### The ways this goes wrong

- **`\S+@\S+`.** Anything with an `@` in it is replaced, and the
  replacement runs to the next space. The order reference goes, and so do the
  comma, the angle brackets and the whole URL.
- **`\S+@\S+\.\S+`.** Requiring a dot spares the order references and still
  takes `release@2024.11`. It also still runs to the next space.
- **Lowercase only.** `JANE@EXAMPLE.COM` and `Example.ORG` get through.
  Customers type their addresses however they like.
- **Naming fields.** `.message` and `.customer.email` are done, and the
  address in `.cc[0]` is not. The next service adds a field nobody told you
  about. Walking every value finds it.
- **`del(.customer.email)`.** The email is gone, and so is a field that a
  dashboard and a join depend on. Redaction masks the value and keeps the
  structure.

Regex redaction is a safety net, not a guarantee. The real fix is not to log
the address in the first place. Log a customer ID, and look the address up
when you need it.

</details>
