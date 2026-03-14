We are developing a tool which updates ldap users via ldapmodify. The scripts connects to a postgres database and reads group memberships.
It thhen reassigns groups based on configured rules, make sure to only modify groups statet in config.yaml.

For testing:
- Fill the database with test user (seeding)
- Give them existing groups.

Here are the credentials for a testing ldap server:

192.168.178.65:389
cn=admin,dc=ffld,dc=de
Password: bbf32sds

Postgres credentials are user: postgres, db: db, pw: postgres

The script should be written using bash. Make it readable and battle-proof. Also add a yaml configuration to create ldap users if not existing.
The tool is called "ldap-usergroup-sync".

Person numbers:

Can be derived from table people. THere are two columns, one is called "persontypeId" and one is called "personNumber". The field personNumber is used as uidNumber in ldap.

In table persontypes the different types are described.

You need to check personDepartments and personFunctions.

In personDepartments respect memberFrom and MemberUntil.

In personfunctions are functions for persons stated, respect validFrom and validUntil.

For example user 1756 is Korbfahrer and Atemschutzgeräteträger.

1) add to all ldap users:
   - uidNumber: derived form personal number (unique, 4 digits)
   - homeDirectory: /home/p-[uidNumber]
   - gidNumber: 100
2) update group assignments (respect date range of membership, if empty assign nevertheless)
3) Group Mapping via yaml configuration
4) Log changes
4) Run via cron job
