---
title: "The support index stopped taking tickets at 02:14"
---

## The situation

Every support ticket is indexed in OpenSearch, and the support team searches
it all day, often by a customer's own custom fields: "every open ticket where
this customer's contract tier is gold". Last night's run refused most of the
tickets:

```
cat /obs/opensearch/last-run.txt
indexed 415 of 1200 tickets; 785 rejected, written to /obs/opensearch/dead-letter.ndjson
    785  Limit of total fields [1000] has been exceeded
```

A ticket looks like this. Every customer defines their own custom fields,
and each has an ID of its own:

```json
{"ticket_id": "T-00042", "ts": "2026-11-15T00:42:54Z", "tenant": "t217",
 "status": "open", "priority": "p2", "subject": "export times out",
 "custom": {"cf_3641187": "gold", "cf_3622952": 120}}
```

Writes and searches go through the alias `support`, which points at the index
`support-v1`. `ticket-ship FILE` is the desk's shipper. It indexes each
ticket by its `ticket_id`, so shipping one twice leaves one copy, and it
writes whatever is refused to `/obs/opensearch/dead-letter.ndjson`.
`/obs/opensearch/tickets.ndjson` is all 1200 of last night's tickets.

OpenSearch is at `http://opensearch:9200` from the box, and at
<http://localhost:19200> from your machine.

## How a mapping explodes

An index's **mapping** gives every field a type, and OpenSearch keeps it in
the cluster state, which every node holds in memory. By default the mapping
is **dynamic**: the first time a document has a field the mapping does not
know, OpenSearch adds it. A string becomes two fields, `text` for full-text
search and a `.keyword` sub-field for exact matches.

That is convenient when the fields are fixed. When the keys are data, as
these custom field IDs are, every new customer adds fields, and nothing
removes them. `index.mapping.total_fields.limit`, 1000 by default, is the
fuse. Once the index reaches it, every document with a new field is refused,
and documents with only known fields still go in. The shipper sees partial
success, not an outage.

```
curl -s opensearch:9200/support-v1/_mapping | jq '.[].mappings.properties.custom.properties | length'
```

What bounds a mapping:

- **`dynamic`** on the mapping or on any object in it. `true` adds new fields.
  `false` keeps them in `_source`, so they come back with the document, but
  does not index them, so they cannot be searched. `strict` refuses the whole
  document.
- **`flat_object`**, an OpenSearch field type for an object whose keys are
  data. The whole object is one field in the mapping, and every key and
  value inside it is still searchable with dotted paths, such as
  `custom.cf_3641187`. Every value is indexed as a string.

You cannot change an existing field's type in place. The way out is a new
index with the mapping you want, then `_reindex` to copy the documents
across, then moving the alias. One `_aliases` request with a `remove` and an
`add` applies both at once, so nothing writes to or searches the alias while
it points at neither index.

## Your objectives

- Writes through `support` go to an index whose mapping does not grow when
  customers add custom fields, and that does not let new top-level fields in
  either.
- Support can still find tickets by custom field.
- Every one of last night's 1200 tickets is in the index behind `support`,
  exactly once.

## What you're being graded on

The check sends 20 tickets from new customers through `support`, with 600
custom fields nobody has seen:

- all 20 are accepted, and the write index's mapping does not grow
- the write index's mapping has `dynamic` set to `false` or `strict`
- a search for one of the new custom fields finds its ticket
- every `ticket_id` in `/obs/opensearch/tickets.ndjson` is found through
  `support`, and none of them twice

<details>
<summary>Hint 1 — the mapping</summary>

Map the fields every ticket has, with types that suit them (`keyword` for
IDs and statuses, `date` for `ts`), set `"dynamic": false` at the top, and
make `custom` a `flat_object`.

</details>

<details>
<summary>Hint 2 — the 1200</summary>

415 tickets are in `support-v1`, and 785 are in the dead-letter file. Both
have to end up in the new index, and `support-v1` has to leave the alias.

</details>

<details>
<summary>Solution</summary>

```
O=http://opensearch:9200
curl -s -XPUT $O/support-v2 -H 'Content-Type: application/json' -d '{
  "settings": {"number_of_shards": 1, "number_of_replicas": 0},
  "mappings": {
    "dynamic": false,
    "properties": {
      "ticket_id": {"type": "keyword"},
      "ts":        {"type": "date"},
      "tenant":    {"type": "keyword"},
      "status":    {"type": "keyword"},
      "priority":  {"type": "keyword"},
      "subject":   {"type": "text"},
      "custom":    {"type": "flat_object"}
    }
  }
}'
curl -s -XPOST "$O/_reindex?refresh=true" -H 'Content-Type: application/json' \
  -d '{"source": {"index": "support-v1"}, "dest": {"index": "support-v2"}}'
curl -s -XPOST $O/_aliases -H 'Content-Type: application/json' -d '{"actions": [
  {"remove": {"index": "support-v1", "alias": "support"}},
  {"add": {"index": "support-v2", "alias": "support", "is_write_index": true}}
]}'
ticket-ship /obs/opensearch/dead-letter.ndjson
```

The mapping now has seven fields, and it will have seven fields however many
customers sign up. A search such as
`{"query": {"match": {"custom.cf_3641187": "gold"}}}` still works.
`support-v1` can be deleted once you have checked the counts.

### The ways this goes wrong

- **Raising `total_fields.limit`.** The tickets go in, and the mapping goes
  on growing by one or two fields per new key. Every field costs memory on
  every node and time on every mapping update. The next fuse is the
  cluster's.
- **`dynamic: false` on `custom`, or `enabled: false`.** The mapping stops
  growing, and the custom fields are kept in `_source` and indexed nowhere.
  Support's searches by custom field return nothing, and nothing reports an
  error.
- **`dynamic: strict`.** Every ticket with a custom field the mapping does not
  name is refused, which is every new customer's. It is the same loss of
  tickets, with a clearer error.
- **`flat_object` with `dynamic` left at `true` on the top level.** `custom`
  is bounded, and the next client that puts its own fields at the top level
  repeats the problem.
- **Moving the alias without reindexing.** The 415 tickets that did get in
  stay in `support-v1`, which nothing searches any more.
- **Adding `support-v2` to the alias without removing `support-v1`.** With two
  indices and no write index, every write through the alias is refused.
  With a write index, every search returns the tickets in both twice.
- **Not replaying the dead-letter file.** 785 tickets were refused once and
  are in no index.

</details>
