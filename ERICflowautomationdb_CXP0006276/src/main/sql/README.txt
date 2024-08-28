Guidelines for Introducing a new DDL
-------------------------------------
1. DDLs should be versioned. For each schema change a new DDL should be introduced.

2. Within a sprint, Major version of DDL should remain un-altered, however, minor version should be incremented with each schema modification.
   (For example, first DDL file introduced in a sprint is 'FlowAutomationSchema_1.0.0', the next DDLs within the sprint should be
   'FlowAutomationSchema_18.12.0' and so on.)

3. All the DDLs should be idempotent.

4. Schema changes provided in a single DDL should be executed with in a sql function. Make sure the function is deleted after executing the changes.