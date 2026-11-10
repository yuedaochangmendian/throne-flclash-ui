# Routing Rules Specification

## Purpose

Defines management and application of routing rules and routing profiles: how the user defines domain/IP-based traffic rules, how rules are grouped into reusable routing profiles, and how the active profile shapes per-connection routing decisions.

## Requirements

### Requirement: Routing rule definition
The app SHALL let the user create routing rules that match traffic by domain lists, IP CIDR lists, and port, and assign each matched rule an outbound action (proxy, direct, block) chosen from available profiles.

#### Scenario: Domain rule to direct
- **WHEN** the user adds a rule matching a domain to Direct and starts the VPN
- **THEN** traffic to that domain bypasses the proxy

### Requirement: Rule ordering
Routing decisions SHALL evaluate rules in the user-defined order and apply the first matching rule.

#### Scenario: Overlapping rules
- **WHEN** two rules both match a destination but assign different actions
- **THEN** the earlier rule in the list determines the action

### Requirement: Routing profiles
The app SHALL group rules into named routing profiles (route configurations), each selectable as the active routing profile, and persist the user's choice across restarts.

#### Scenario: Switch routing profile
- **WHEN** the user selects a different routing profile
- **THEN** subsequent connections are routed according to that profile's rules

### Requirement: Rule set references
Routing rules SHALL be able to reference external rule sets, and the app SHALL report unresolvable rule set references as configuration errors rather than silently ignoring them.

#### Scenario: Missing rule set
- **WHEN** a rule references a rule set that cannot be resolved at connection start
- **THEN** the app surfaces a routing configuration error

### Requirement: Rule editing surface
Rules SHALL be editable on a screen of their own, separate from the profile's settings form, with search, drag ordering and JSON fragment import.

#### Scenario: Reorder persists
- **WHEN** the user drags a rule to a new position within its profile
- **THEN** the stored order matches the visible order and the router evaluates it that way

#### Scenario: Built-in profile
- **WHEN** the user opens the rules of a built-in profile
- **THEN** its rules are shown read-only, with no drag handle, edit or delete action
