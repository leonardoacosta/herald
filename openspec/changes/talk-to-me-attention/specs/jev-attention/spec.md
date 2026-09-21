# jev-attention capability delta

## ADDED Requirements

### Requirement: JA1 Optional typed classification

Herald SHALL implement off/shadow/enforce Jev integration with the pinned model, atomic questions, strict typed validation and bounds defined in design.md section 7. Jev SHALL classify redacted context only and SHALL not synthesize prose or choose arbitrary tools or destinations.

#### Scenario: Shadow decision

- **WHEN** a configured shadow event is evaluated
- **THEN** provider suggestions, validated probabilities, model and measured latency are recorded while baseline delivery remains unchanged

#### Scenario: Provider outage or inconsistent answer

- **WHEN** Jev times out, returns invalid/nonfinite probabilities, the wrong model, or conflicting classifications
- **THEN** Herald follows deterministic policy, records a safe failure reason and never retries within the decision path

#### Scenario: Off or unsafe input

- **WHEN** Jev is off or event context cannot be safely reduced to approved fields
- **THEN** no provider call occurs and no raw transcript, secret, attachment or untrusted instruction is sent

### Requirement: JA2 Protected events and calibrated enforcement

Jev SHALL never suppress explicit speech, needs_decision, blocked, or unrecovered failure. Routine enforcement SHALL require the frozen held-out calibration and thresholds in design.md section 7 plus explicit operator activation. Suppression SHALL be reversible through off mode and auditable.

#### Scenario: Calibration meets acceptance

- **WHEN** the labeled held-out evaluation meets mandatory recall, routine interruption reduction and measured latency gates
- **THEN** a versioned report is presented and enforce remains disabled until the operator explicitly activates the evaluated model/policy pair

#### Scenario: False-negative pressure or model change

- **WHEN** a model recommends silence for a protected event or the deployed model/policy differs from the calibrated pair
- **THEN** protected events use baseline routing and enforcement for an uncalibrated pair is disabled

#### Scenario: Insufficient or failed experiment

- **WHEN** labels are missing, baseline has no unwanted alerts, or evaluation misses a gate
- **THEN** the report states blocked or failed, shadow can continue, and the feature is not claimed production-safe
