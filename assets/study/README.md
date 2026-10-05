# Native study vocabulary

`vocabulary.json` is the single native JSON catalog consumed by Flutter. It is generated from the reviewed web `prototypes/study-mobile/src/content.js` canonical catalog and ECDICT source module. Four curated cores: daily 1000, highschool 1500, CET4 1500, CET6 1500; ECDICT union 2468 words, plus six separately authored rich preview cards, total 2474 unique IDs.

ECDICT is MIT licensed (`LICENSE.ecdict`), pinned upstream commit `bc015ed2e24a7abef49fc6dbbb7fe32c1dadaf8b`. Upstream original CSV Git blob was independently hash verified during web asset preparation. Source metadata is retained in JSON and in web `assets/vocabulary/manifest.json`; no downloaded CSV remains. Book selection is curated, not claimed to cover an official complete examination syllabus.

Chinese definitions and phonetics preserve source text. Missing phonetics/examples remain empty. Rich card example sentences are independently authored UI examples and explicitly labeled; they are not attributed to ECDICT. Cross-book stable word IDs share state, while separate skill units retain separate learning evidence.

Rebuild format only when canonical source changes: import the web content module in Node and JSON serialize its words/books/source metadata. Do not redownload or duplicate source CSV/model assets.
