# Users API

The users API lists accounts and their roles for the admin console.

## List users

GET /api/users returns every account with an active flag and the
account creation date.

## Rename a user

POST /api/users/:id/rename accepts a JSON body with a name field
and returns the updated account record.
