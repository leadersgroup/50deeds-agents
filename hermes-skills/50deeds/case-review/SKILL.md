---
name: 50deeds-case-review
description: Review a 50deeds deed order (deed, signing package, tax forms) against the vesting deed, trust documents and state recording rules before release, and report ranked issues. Use when staff ask to review, QC, check or re-check a case, order or signing package.
version: 1.0.0
platforms: [linux]
metadata:
  owner: 50deeds
  managed_by: leadersgroup/50deeds-agents (overwritten on every deploy; do not edit in place)
---

# 50deeds case review

Pre-release QC of a deed order. The goal is to catch anything that would get
the deed rejected by the recorder, convey the wrong interest, or put a false
statement over a client's signature, before the package goes to the client.
Eve Gu, Esq. is the reviewing attorney on every deed; this review supports
her sign-off, it does not replace it.

## When to use

- "Review case 20261002-101834", "QC this signing package", "check the deed
  for 404 Commons Dr", "re-check, processor says it's fixed".
- Prep Only orders too, but deed only (see Order types).

## 1. Find the files

Case files are in Google Drive under `QCD_live` › `1. eFile:Paper:In-person` ›
`<state>`. Retail-client cases are grouped by state and month; Client Portal
orders by case number (e.g. `20261002-101834`).

- Locate the case folder, then list every subfolder in one query:
  `'<id1>' in parents or '<id2>' in parents ...`. Folder traversal is more
  reliable than full-text search for finding all of a case's files.
- Collect: the deed (draft), the signing package (cover page, execution
  instructions, Certificate of Authenticity, Section III disclaimer), state
  tax/transfer forms, the vesting (prior) deed, the trust document or
  Certificate of Trust, and any death certificate, POA, or LLC documents.
- Re-check requests: filter by `modifiedTime > '<last review time>'` to see
  what actually changed before re-reviewing. Say which files changed.
- Read PDFs and .docx with the preinstalled libraries (pymupdf, pymupdf4llm,
  python-docx). Do not create a virtualenv or pip install anything.
- If a needed document is missing (no vesting deed, no trust document),
  say so first; review what is there and mark the affected checks "not
  verified".

## 2. Do NOT flag these (house rules)

These are normal for 50deeds and must never appear as issues:

1. Trust date blank or in the future, on the deed or the Certificate of
   Trust. Attorneys often order the deed before the trust is signed.
2. The homeowner (grantor) listed as the deed preparer. 50deeds always does
   this.
3. Anything inside `CaseSummary_<order>.docx` (blank grantor, grantee,
   instructions, "Trust Document Present: No", etc.). Ignore the case summary
   entirely; review the actual documents.
4. Massachusetts Declaration of Homestead for Homes Owned by Trustee(s):
   blank beneficiary name (item 2).
5. Virginia trust-funding deeds citing Va. Code § 58.1-811(A)(11) for the
   revocable inter vivos trust exemption. (A)(11) is correct; do not suggest
   (A)(12).

## 3. Checks

Compare the deed against the vesting deed and the trust document line by
line. Quote the exact text when you flag something.

**Parties and title**
- Grantor names match record title exactly (middle initials, suffixes,
  "Jr."), and every owner of record is a grantor or accounted for.
- How title is held (joint tenants, tenants by the entirety, tenants in
  common, community property, sole) and whether the order conveys all of it.
- A deceased owner on title: if held with survivorship, an affidavit of
  survivorship (recorded with the death certificate) must come first; if no
  survivorship words, it is a probate matter. Check the vesting deed's
  words, not the order.
- Grantee: trustee name(s) and trust name match the trust document;
  successor/sole trustee language is right if a trustee has died.
- Marital status recited where the state needs it, and the spouse joins
  where the state requires it (dower/curtesy, homestead, elective share,
  NJ § 3B:28-3).
- Entity grantor (LLC): operating agreement showing signing authority; if
  more than one member, a resolution signed by all members authorizing the
  signer.
- POA signer: the POA is present, covers real property, and the signature
  block reads correctly for an agent.

**Property**
- Legal description matches the vesting deed word for word (no dropped
  calls, no duplicated lead-in text, "BEING the same premises" clause
  present where the state expects it).
- Parcel/APN, lot and block, county, municipality and address are consistent
  across deed, cover sheet and tax forms.
- Fractional interests: the fraction is stated clearly; for a series of
  partial deeds, prefer whole-property percentages, and if remaining-interest
  fractions are used each deed also states the whole-property percentage.

**Instrument**
- Deed type named and covenants match it (quitclaim by default for trust
  funding; warranty if the ordering attorney asked, e.g. NC practice).
- Consideration clause is consistent with the transfer tax claimed (no
  "$10 and other valuable consideration" next to a form that says $0 if the
  state reads that as taxable, and vice versa).
- No warranty clause that references exceptions it never states.
- State statutory recitals present (confidentiality notices, true
  consideration statements, tax statement address, preparer block, return
  address).
- Acknowledgment form fits the state where it will be notarized (a deed
  notarized in another state needs that state's form or a compliant one).
- Witness requirements and signature lines (names printed beneath
  signatures where required).

**Tax and recording forms**
- Every form the county needs is present and complete: checkboxes selected,
  exemption claimed on the form itself where required, no broken or blank
  PDF pages.
- Certifications are true for these clients (residency, smoke detector,
  SSN/EIN, seller/buyer roles). A false certification is a blocker.
- New York orders: SSN is required for both grantor and grantee.

**Signing package** (not for Prep Only)
- Execution instructions match the deed's witness/notary needs and the
  state where signing happens.
- Certificate of Authenticity and Section III disclaimer present.
- Original-deed instruction: client may scan/email the signed deed to start
  recording, but must mail the original to the Sandy Springs office.

State-specific traps: see `references/state-rules.md`. Check the
state's entry before you finish. For counties, also check the team's
"Recording Notes by County" doc for that county when you can reach it.

## 4. Order types

- **Standard:** deed + signing package + forms. Full review.
- **Prep Only:** deed only. No signing package, so do not flag a missing
  execution page, Certificate of Authenticity or Section III disclaimer.

## 5. Report

Reply in this shape, short and specific:

```
Case <id> — <property address>, <county>, <state>
Files reviewed: <list> (changed since last review: <list or "n/a">)

BLOCKERS (fix before release)
1. <issue> — <document, page/section> — "<exact text>" — Fix: <exact fix>

FIX BEFORE RECORDING
...

MINOR / CONFIRM WITH CLIENT
...

VERIFIED
- Legal description matches vesting deed (Book/Page …)
- Trust name and trustees match trust document
- ...

NOT VERIFIED (missing documents)
- ...
```

Rules for the report:
- Rank by consequence: rejection or wrong conveyance first, false
  certifications next, cosmetic last.
- Every issue cites the document and quotes the text. No issue without
  evidence.
- Separate errors on the face of the document (they stand even if the
  processor says it is correct) from order-dependent questions (marital
  status, which spouse is conveying), which go to "confirm with client".
- If a processor disputes an item, re-read the file and either withdraw it
  or quote the text again. Don't drop an issue just because someone
  disagrees.
- If nothing is wrong, say "No issues found" and list what was verified.

## Pitfalls

- Reviewing the case summary instead of the documents. The case summary is
  not evidence of anything.
- Trusting the order over the vesting deed for who is on title.
- Calling a blank or future trust date a defect (house rule 1).
- Flagging the homeowner-as-preparer line (house rule 2).
- Reviewing a stale copy: always check `modifiedTime` on a re-check.

## Changing this skill

This skill is managed in the leadersgroup/50deeds-agents repo and is
replaced on every deploy, so edits made here are lost. When staff correct a
review rule ("don't flag X", "in state Y always Z"), say that the rule should
be added to the case-review skill in the repo, and quote the exact rule.
