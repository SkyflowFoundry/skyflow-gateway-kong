# Healthcare scenario for the skyflow-kong-poc demo.
#
# A "scenario" is the swappable content layer of the demo: one PII-laden prompt,
# the highlight list, and a recurring-entity pair for the referential-integrity
# proof. steps.sh sources this file (pick another with SCENARIO=demo/scenarios/<x>.sh).
# To re-skin the demo for another vertical (finance, legal, support), copy this
# file, swap PROMPT / HL_SENSITIVE / RECUR_* — nothing in steps.sh changes.
#
# This one is deliberately dense: a single follow-up note that makes real Skyflow
# light up ~12 entity types, several with MULTIPLE instances of the same type, so
# the breadth and the deterministic-token behavior are both visible in one frame.

SCENARIO_LABEL="Healthcare — patient follow-up note"

# --- Act 1: one rich prompt, reused across raw / de-identified / re-identified ---
# Entity types this exercises (verified live against a real vault):
#   NAME x2 (Maria, Elena)  NAME_MEDICAL_PROFESSIONAL (Dr. Reyes)  OCCUPATION (Dr.)
#   HEALTHCARE_NUMBER (MRN)  ORGANIZATION_MEDICAL_FACILITY (Mercy General)
#   CONDITION x2 (Type 2 diabetes, hypertension)  DRUG x2 (metformin, lisinopril)
#   DOSE x2  EMAIL_ADDRESS x2  PHONE_NUMBER
PROMPT='{"messages":[{"role":"user","content":"Draft a friendly follow-up note. Patient Maria Gonzalez (MRN 88213-A) has Type 2 diabetes and hypertension. Dr. Alan Reyes at Mercy General Hospital started her on metformin 500mg twice daily and lisinopril 10mg. Contact her at maria.g@example.com or 415-555-0132. Emergency contact: her sister Elena Gonzalez (elena.g@example.com)."}]}'

# Raw PII to highlight red in the payload/output (Skyflow tokens auto-highlight green).
HL_SENSITIVE="Maria Gonzalez|Elena Gonzalez|Alan Reyes|Mercy General Hospital|88213-A|Type 2 diabetes|hypertension|metformin|lisinopril|maria.g@example.com|elena.g@example.com|415-555-0132|500mg twice daily|10mg"

# --- Referential-integrity proof: two SEPARATE requests, same patient ------------
# Maria Gonzalez recurs in both. With VAULT_TOKEN against the real vault, the token
# is deterministic per value, so both requests emit the IDENTICAL [NAME_...] token —
# that stable mapping is what lets the model keep the thread across turns.
RECUR_PROMPT_A='{"messages":[{"role":"user","content":"Summarize the care plan for Maria Gonzalez (MRN 88213-A)."}]}'
RECUR_PROMPT_B='{"messages":[{"role":"user","content":"Book a follow-up appointment for Maria Gonzalez next week."}]}'
