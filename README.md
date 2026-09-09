# Lead Matter Questions

Captures a matter-specific intake questionnaire on the Lead record page.

The questionnaire lives in 15 paired `Question_N__c` / `Answer_N__c` fields on
Lead. Which questions apply is configured declaratively in `Lead_Question__mdt`,
keyed by `Matter_Type__c` and an optional `Sub_Type__c`.

| Piece | What it is |
|---|---|
| `LeadQAController` | `with sharing` Apex controller. Reads, resolves and saves the questionnaire. |
| `LeadQAControllerTest` | 22 tests: happy path, reset semantics, validation, limits, permissions. |
| `leadQuestionAnswer` | The LWC. Drop it on the Lead Lightning Record Page. |

## How it behaves

**On load** the component reads whatever is already stored on the Lead and shows
only the slots that have a question in them.

**Get Matter Specific Questions** rebuilds the list from `Lead_Question__mdt` for
the Lead's current Matter Type, preferring the Sub Type record and falling back
to the Matter Type record. This is a draft — nothing is written until Save.

An answer is carried over **only where the identical question is still asked**.
The match is on question text rather than slot number, so an answer follows its
question if the configuration reorders it, and an answer to a question that is
no longer asked is dropped rather than silently re-labelled. Because this
discards work, the user is asked to confirm when answers already exist.

**Save** overwrites all 15 slots. Every slot the component did not send is set to
null — question *and* answer — so a Lead never keeps questions belonging to a
Matter Type it no longer has. A question left unanswered is still recorded, with
a null answer.

## What changed from the original

The behaviour above is the fix for the reported defect: switching a Lead from a
10-question matter type to a 4-question one used to leave the previous answers
attached to the record, because the old `getRecords` overwrote the `Question__c`
fields but never touched the `Answer__c` fields.

Alongside that:

- **`saveLead(Lead)` is gone.** It accepted a whole SObject from the browser and
  `upsert`ed it, so any authenticated user could write any field on any Lead —
  or create one, since an `upsert` with no Id inserts. The replacement takes a
  record Id plus question text and answers, re-reads the Lead server-side, and
  writes only the 30 questionnaire fields.
- **Sharing and FLS are enforced.** The original class declared no sharing
  keyword, which means `without sharing` at an `@AuraEnabled` entry point, and
  did no CRUD/FLS checking at all. Every query and the DML now run in
  `USER_MODE`.
- **Queries that threw on the ordinary case are fixed.** `returnLeadRecord` used
  a bare `[SELECT ...]` assignment filtered on `Matter_Type__c != null`, so it
  threw `List has no rows for assignment` for exactly the Lead the UI was built
  to prompt about. The metadata query had the same shape and no `LIMIT`.
- **Errors reach the user.** The old catch logged to `System.debug` and returned
  null, so a missing metadata record looked identical to a working component
  with no questions.
- **Two SOQL calls on init became one**, and the 15 copy-pasted markup blocks and
  field assignments became loops.

## Deploying

1. Deploy `force-app`. The Apex, the LWC and the tests have no other dependencies.
2. Edit the **Lead Lightning Record Page**, remove the old `LeadQA` Aura
   component, and drop **Matter Questions** in its place.
3. Delete the retired `LeadQACtrl` class and `LeadQA` Aura bundle once no page
   references them.

Requires API 61.0+ for `USER_MODE` and `update as user`. On an older org, swap
those for `WITH SECURITY_ENFORCED` plus `Security.stripInaccessible`.

### Permissions

Users need Read on Lead plus Read/Edit on `Matter_Type__c`, `Matter_Sub_Type__c`
and the 30 `Question_N__c` / `Answer_N__c` fields. Without Edit the component
renders read-only and disables both buttons rather than failing at save time.

## Working on it

```bash
npm install
npm run test:unit   # Jest, 12 tests
npm run lint        # ESLint, @salesforce/eslint-config-lwc
npm run pmd         # Apex static analysis (needs Java 17+)
```

Apex tests need a real org: `sf apex run test -n LeadQAControllerTest -r human`.

CI runs lint, Jest and PMD on every push. The Apex compile and test job is
skipped unless an `SFDX_AUTH_URL` repository secret is set — get one with
`sf org display --verbose --json` against the target sandbox and read
`result.sfdxAuthUrl`.

### Known static-analysis deviations

PMD reports `LeadQAController` at a cognitive complexity of 77 against a
threshold of 50, and `validateRow` at a cyclomatic complexity of 11 against 10.
Neither is suppressed. The class is cohesive and every method is small — the
count is the sum of many short methods, not one long one. If it needs to come
down, the honest fix is to extract the schema introspection (the static
initialiser and the field maps) into a `LeadQASchema` class, not to raise the
threshold.

`Lead_Question__mdt` records cannot be inserted in a test, so the controller
exposes a `@TestVisible mockQuestionConfigs` seam and the tests configure
question sets in memory. Matter Type values are read from the picklist describe
rather than hard-coded, so the class does not break in an org that spells them
differently.
