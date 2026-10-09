# Lab 3

Instructions for this section will be provided in class and on Blackboard when we reach it.

Put your work for Lab 3 in this folder.

1. why a real account would use OIDC rather than stored keys?: A production environment uses OpenID Connect (OIDC) to eliminate the risk of leaked or hardcoded static credentials, instead establishing federated trust to issue short-lived, automatically rotating identity tokens on demand.

2. why this course uses session-scoped secrets and what limits the damage if they leak?: Because A real account uses OIDC. a registered GitHub's token issuer as an identity provider and create an IAM role that trusts it.  it needs iam:CreateOpenIDConnectProvider and iam:CreateRole, and Academy denies IAM writes
