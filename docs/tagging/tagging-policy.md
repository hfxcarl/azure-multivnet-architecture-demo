# Azure Tagging Policy (Student & Learning Lab Environment)

## Purpose
This policy outlines best practices for tagging Azure resources in a learning and development environment, particularly for users pursuing certification (e.g., AZ-104, DP-700) and transitioning into data engineering and analytics roles.

## Objectives
- Organize resources by learning project and topic
- Enable cost tracking and cleanup
- Maintain consistency and clarity in resource classification
- Prepare for scalable tagging strategies in enterprise scenarios

---

## Tagging Guidelines

| Tag Key       | Description                                                  | Example Values                   |
|---------------|--------------------------------------------------------------|----------------------------------|
| `Project`     | Identifies the broader learning objective or cert path       | `learn-az104`, `dp700`           |
| `Category`    | Classifies the resource function or Azure service type       | `network`, `compute`, `storage`  |
| `Topic`       | Focus area for study or lab purpose                          | `dns`, `vnet`, `rbac`, `vmss`    |
| `Environment` | Distinguishes between lab, dev, and production environments  | `lab`, `dev`, `prod`             |
| `Phase`       | Indicates certification stage or roadmap                     | `az104`, `dp700`, `advanced-labs`|
| `Owner`       | Identifies the creator or responsible user                   | `john.doe`, `yourname`           |
| `CostCenter`  | Helps track cost by function or intent                       | `training`, `personal`           |
| `DecomDate`   | Optional date for automatic cleanup or review                | `2025-08-01`                     |

---

## Best Practices

1. **Apply tags consistently** across all resources, resource groups, and subscriptions.
2. **Use lowercase or kebab-case** for tag values (`learn-az104`, not `Learn-AZ104`).
3. **Enforce required tags** via Azure Policy when working in team or production settings.
4. **Include a `DecomDate`** to support periodic cleanup of unused or test resources.
5. **Avoid sensitive information** in tag values (e.g., passwords or keys).
6. **Keep tag keys limited and meaningful**—Azure supports up to 50 tags per resource.

---

## Tag Application Example (JSON for Azure CLI)

Save this as `tags.json`:

```json
{
  "Project": "learn-az104",
  "Category": "network",
  "Topic": "dns",
  "Environment": "lab",
  "Phase": "az104",
  "Owner": "yourname",
  "CostCenter": "training",
  "DecomDate": "2025-08-01"
}
