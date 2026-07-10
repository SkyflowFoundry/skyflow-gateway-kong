"""Toy patient-intake module — the file the coding agent works on in Act 2.

It holds synthetic PHI (names, MRNs, conditions, meds, providers, contacts) so we
can show a real coding-agent CLI reason over sensitive data WITHOUT that data ever
reaching OpenAI in the clear. The agent talks to OpenAI through the Kong AI Gateway,
where the skyflow-deidentify plugin swaps every PHI value for a deterministic vault
token on the way out and restores it on the way back. OpenAI only ever sees
[NAME_xjv74g]-style tokens; the developer sees real names in the answer.

Because the tokens are deterministic, "Maria Gonzalez" maps to the SAME token every
time she appears — within this file and across every turn of the conversation — so
the model can keep the patients straight even though it never learns who they are.
"""

PATIENTS = [
    {
        "name": "Maria Gonzalez",
        "mrn": "88213-A",
        "dob": "1984-03-12",
        "conditions": ["Type 2 diabetes", "hypertension"],
        "medications": ["metformin 500mg twice daily", "lisinopril 10mg"],
        "provider": "Dr. Alan Reyes",
        "facility": "Mercy General Hospital",
        "email": "maria.g@example.com",
        "phone": "415-555-0132",
        "emergency_contact": {"name": "Elena Gonzalez", "email": "elena.g@example.com"},
    },
    {
        "name": "David Okafor",
        "mrn": "77120-B",
        "dob": "1971-11-02",
        "conditions": ["asthma", "high cholesterol"],
        "medications": ["albuterol inhaler", "atorvastatin 20mg"],
        "provider": "Dr. Sarah Lin",
        "facility": "Mercy General Hospital",
        "email": "d.okafor@example.com",
        "phone": "415-555-0177",
        "emergency_contact": {"name": "Grace Okafor", "email": "g.okafor@example.com"},
    },
]


def active_medications(patient):
    """Return the list of current medications for a patient record."""
    return patient["medications"]


def find_patient(mrn):
    """Look up a patient by medical record number."""
    for p in PATIENTS:
        if p["mrn"] == mrn:
            return p
    return None


# NOTE: a reviewer would scan each patient's `medications` for risky drug-drug
# interactions. The Act 2 demo (demo/act2/run.sh) asks the agent to do exactly
# that by READING this file — it reasons over the PHI above, while the gateway
# ensures OpenAI only ever sees Skyflow tokens for it.
