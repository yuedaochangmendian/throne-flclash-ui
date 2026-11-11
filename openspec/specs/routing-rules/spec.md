# Routing Rules Specification

## Purpose

Defines management and application of routing rules: how the user defines domain/IP-based traffic rules, how one shared pool applies them to every configuration, and how that pool shapes per-connection routing decisions.

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

### Requirement: Shared rule pool
The app SHALL keep one shared rule pool, applied in front of every configuration's own rules, and SHALL edit it on the Routing screen itself. The user does not select a routing profile: the pool is the default routing for every configuration.

#### Scenario: Shared pool
- **WHEN** the user adds a rule on the Routing screen
- **THEN** every configuration evaluates that rule before its own rules, and the first match wins

#### Scenario: Per-configuration opt-out
- **WHEN** the user turns a pool rule off for one configuration
- **THEN** that configuration skips it while every other configuration keeps it

### Requirement: Rule set references
Routing rules SHALL be able to reference external rule sets, and the app SHALL report unresolvable rule set references as configuration errors rather than silently ignoring them.

#### Scenario: Missing rule set
- **WHEN** a rule references a rule set that cannot be resolved at connection start
- **THEN** the app surfaces a routing configuration error

### Requirement: Rule editing surface
Rules SHALL be editable with search, drag ordering and JSON fragment import. The shared pool is edited on the Routing screen; a configuration's own rules are edited on their own screen, reachable from the Routing screen's menu.

#### Scenario: Reorder persists
- **WHEN** the user drags a rule to a new position within its profile
- **THEN** the stored order matches the visible order and the router evaluates it that way

#### Scenario: Built-in profile
- **WHEN** the user opens the rules of a built-in profile
- **THEN** its rules are shown read-only, with no drag handle, edit or delete action
