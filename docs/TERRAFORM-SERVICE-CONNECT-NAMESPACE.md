# Terraform Service Connect Namespace Coexistence

## Purpose

The existing console-created ECS environment may already use this Service Connect namespace:

```text
group3.internal
```

The Terraform environment also needs service discovery so the services can call each other by name:

```text
order → inventory → payment
```

This note explains how the Terraform namespace should safely coexist with the old manual AWS setup.

## Current decision

Terraform creates a new private Cloud Map namespace named:

```text
group3.internal
```

inside the new Terraform-managed VPC:

```text
devops-g3-iac-vpc
10.30.0.0/16
```

This is expected to be safe because private DNS namespaces are attached to a VPC. The old console environment uses the default VPC, while Terraform creates a separate VPC.

## Why this matters

Service Connect names should stay simple for application code:

```text
http://inventory:3002
http://payment:3003
```

The applications should not need to know task IP addresses, subnet IDs, or AWS resource IDs.

## If AWS rejects duplicate namespace creation

If Terraform apply fails because the namespace name already exists or conflicts, the team should not manually edit AWS resources during the apply.

Use one of these safe options:

1. Import the existing namespace only if it belongs to the same Terraform VPC and is meant to be managed by Terraform.
2. Use a Terraform-only namespace name such as:

   ```text
   iac.group3.internal
   ```

3. Re-run `terraform plan` and review the change before applying.

## Evidence to collect later

After the lab environment is wired and applied, capture:

- the namespace ARN from Terraform output;
- ECS service Service Connect configuration;
- one successful request proving `order → inventory → payment`;
- confirmation that services use names, not IP addresses.
