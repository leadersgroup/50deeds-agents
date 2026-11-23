---
name: 50deeds-case-review
description: Review a 50deeds deed order (deed, signing package, tax forms) against the vesting deed, trust documents and state recording rules before release, and report ranked issues. Use when staff ask to review, QC, check or re-check a case, order or signing package.
version: 1.4.0
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

- Use your own profile's Google sign-in (run Google commands with
  `HERMES_HOME` set to your own profile), search by the literal case ID,
  and keep it read-only.
- Search can return trashed copies, empty duplicate folders, files that
  merely share the name, and parallel trees such as `QCD_live copy`. Walk the
  parent chain and pick the non-trashed folder under the real live root, not
  a similarly named copy, then list its children recursively with
  `trashed=false`.
- When duplicate case folders exist, list each candidate's contents before
  choosing: a correctly named folder can be empty while its duplicate holds
  the working documents.
- Record the Drive path, folder ID, and the document count separately from
  the total item count (documents plus subfolders) so the review is
  auditable.
- Folder traversal (`'<id>' in parents`) is more reliable than full-text
  search for finding all of a case's files.
- Inspect every listed file, including phone photos and payment subfolders.
  If a file holds full card data, a security code, account credentials or
  other unnecessary high-risk personal data, never repeat it: report that
  the file is there and tell staff to remove it from the case folder.
- Collect: the deed (draft), the signing package (cover page, execution
  instructions, Certificate of Authenticity, Section III disclaimer), state
  tax/transfer forms, the vesting (prior) deed, the trust document or
  Certificate of Trust, and any death certificate, POA, or LLC documents.
- Re-check requests: filter by `modifiedTime > '<last review time>'` to see
  what actually changed before re-reviewing. Say which files changed.
- Download the case files into a **fresh, empty** working folder, e.g.
  `$HERMES_HOME/cache/scratch/case_<id>_<timestamp>/`. Never extract from a
  folder that holds an earlier download: stale files and earlier review
  output would be read as current case documents and inflate the count.
  Google API libraries are already installed: never run a setup or
  `pip install` step first.

## 1b. Read the files (do this, in this order)

Run the bundled extractor on the folder. It needs nothing installed:

```
python3 ${HERMES_SKILL_DIR}/scripts/extract_case.py <case folder>
```

It prints, per document, a text file and, for scanned pages only, PNG page
images, all as absolute paths that are known to exist. Phone photos (HEIC,
JPG, PNG) are converted and listed as images too. It skips folders whose
names start with `_` (its own `_extracted` output, earlier `_review` work).

1. Read the **text files** first. Most generated deeds, forms and signing
   packages are fully readable as text.
2. Use vision **only** on the image paths the extractor printed (scanned or
   recorded copies, phone photos, signatures, stamps). Never build or guess
   an image path yourself.
3. If a page you need is not in the list, rerun with `--all-pages`.
4. If the extractor reports `ERROR` for a file, say which file could not be
   read and carry on with the rest. Do not retry the same failing step: if
   a tool fails twice, stop and report what failed.
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
  successor/sole trustee language is right if a trustee has died. Read every
  page of a Certification of Trust and any attached trust information or
  titling page: the attachment may contain the exact required vesting phrase
  even when the certification's operative paragraphs use shorter wording.
- Marital status recited where the state needs it, and the spouse joins
  where the state requires it (dower/curtesy, homestead, elective share,
  NJ § 3B:28-3).
- Entity grantor (LLC): operating agreement showing signing authority; if
  more than one member, a resolution signed by all members authorizing the
  signer.
- POA signer: the POA is present, covers real property, and the signature
  block reads correctly for an agent.

**Property**
- Use the **latest** recorded vesting deed, not just the oldest deed in the
  folder. If the county's transfer history shows a later deed that isn't in
  the folder, mark vesting and the legal description "not verified" and ask
  for that deed. An assessor ownership record supports current ownership but
  does not replace the vesting deed.
- Legal description matches the vesting deed word for word, read through
  the end of the property language, not just the lot-and-block sentence: no
  dropped calls, no duplicated lead-in text, and any reservation, excepted
  parcel, appurtenant easement or exhibit that defines what is conveyed is
  carried over ("BEING the same premises" clause where the state expects
  it). A deed that stops after the parcel description can convey a
  different interest even though its first sentence matches.
- Separate that from "subject to" lists (title exceptions, encumbrances,
  covenants, title-policy language) in a prior warranty deed: do not
  require those in a quitclaim unless state practice, the order, or the
  attorney asks for them.
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
- The deed's consideration recital and every tax affidavit say the same
  thing, read literally: a deed reciting a nominal cash payment conflicts
  with an affidavit saying "no consideration". Send the intended
  consideration and exemption to the reviewing attorney before release.
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

**Signatures and authority**
- Each signature sits in the capacity printed beside it. A trustee or
  grantor who signed only on a witness line has not executed in that
  capacity, and a notary block does not cure a blank operative signature.
- The acknowledgment says the signer acknowledged executing the
  instrument (identity/appearance wording alone is defective).
- Identify authority documents by content, not file name: "COT" can be a
  Certification of Trust or a Certificate of Authenticity.
- Revocable-trust transfer tax exemptions that depend on "no change in
  beneficial ownership": compare the grantors with the trust's present
  beneficiaries. If the evidence isn't in the file, flag it for the
  reviewing attorney as a tax question, not a title defect.

**Versions**
- The signing package must contain the current deed. A DOCX modified after
  its PDF or the assembled package makes the package suspect: compare the
  text of the DOCX, the standalone PDF, and the deed pages inside the
  package, and report the actual difference (or that they match). A
  timestamp a few seconds apart is not a defect by itself.

**Signing package** (not for Prep Only)
- Execution instructions match the deed's witness/notary needs and the
  state where signing happens.
- Certificate of Authenticity and Section III disclaimer present. Check the
  assembled package by page content, not file names; if a part is missing,
  say what the package actually contains.
- Original-deed instruction: client may scan/email the signed deed to start
  recording, but must mail the original to the Sandy Springs office.

State-specific traps: see `references/state-rules.md`. Check the
state's entry before you finish. For counties, also check the team's
"Recording Notes by County" doc for that county when you can reach it.

## 4. Order types

- **Standard:** deed + signing package + forms. Full review.
- **Prep Only:** review the deed and any recording or tax affidavit that
  comes with it. Do not flag a missing execution page, Certificate of
  Authenticity or Section III disclaimer. A generated PDF or `Signing_PKG`
  folder doesn't turn the order into Standard: check any deed or affidavit
  in it for real defects, but don't apply the package checklist just
  because assembly files exist.
- **Already recorded** (a recorded copy or recorder stamp is in the folder):
  compare the prepared deed, the signed scan and the recorded image, and
  put each finding in one bucket: fixed before recording; a package or
  workflow gap that is not in the recorded deed; a defect in the recorded
  deed itself; or a tax/title question for the attorney. Only a defect in
  the recorded deed calls for a corrective deed. Transcribe the instrument
  number, recording date and page count from the stamp. State the corrective-
  deed conclusion explicitly: either `Corrective deed indicated` with the
  recorded defect, or `No corrective deed indicated`. Successful recording
  proves acceptance by the recorder, not that the parties, authority, legal
  description, tax treatment, or execution were substantively correct.
- **Unsigned package:** blank signature, notary and execution-date fields
  are expected. They are not release issues; list them as "complete at
  signing" only if something about them is unclear. This does **not** cover
  certifications or elections: well disclosure, residency, exemption and
  similar checkboxes must carry a truthful selection before recording, and
  before release when the signing instructions don't tell the client to
  make it.

## Time limit

Deliver a verdict in the same run. Read the documents most likely to change
the verdict first: the prior/vesting deed, the prepared deed and its
execution page, the tax form, and the trust or entity authority. If you
cannot finish everything, report what you found and list the exact files and
pages you did not inspect. Never reply with only a progress update, and do
not hand the work to a background task that answers later.

## 5. Report

Reply in this shape, short and specific:

```
Case <id> — <property address>, <county>, <state>
Readiness: <READY / NOT READY FOR RELEASE / NOT READY TO RECORD>
Confidence: <High / Medium / Low> — <what is unverified, if anything>
Source folder: <Drive path> (<folder ID>) — <n> documents / <n> total items
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
- Lead with the readiness verdict and confidence. Lower the confidence when
  county notes, authority evidence, tax treatment or a needed page could not
  be verified, and name the exact unverified check. A missing, stub, stale or
  `needs-review` state/county note is a knowledge gap to name, not a defect
  in the documents.
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
- For an already-recorded case, lead with the recording date, instrument
  number and page count, separate package/workflow gaps from defects in the
  recorded deed, and end the defect section with the explicit corrective-
  deed conclusion.

## Pitfalls

- Reviewing the case summary instead of the documents. The case summary is
  not evidence of anything.
- Trusting the order over the vesting deed for who is on title.
- Calling a blank or future trust date a defect (house rule 1).
- Flagging the homeowner-as-preparer line (house rule 2).
- Reviewing a stale copy: always check `modifiedTime` on a re-check.
- Calling vision on page images you assumed were rendered. Only use paths
  the extractor printed.
- Extracting from a scratch folder that already holds an earlier download.
- Taking the vesting from the oldest deed in the folder when county history
  shows a later one.
- Using another review skill. This is the only 50deeds case review skill;
  do not create or follow a separate one.

## Changing this skill

This skill is managed in the leadersgroup/50deeds-agents repo and is
replaced on every deploy, so edits made here are lost. When staff correct a
review rule ("don't flag X", "in state Y always Z"), say that the rule should
be added to the case-review skill in the repo, and quote the exact rule.
