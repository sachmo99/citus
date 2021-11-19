/*-------------------------------------------------------------------------
 *
 * pg_get_object_address.c
 *
 * Copied functions from Postgres pg_get_object_address with acl check.
 * We need to copy that function to use obtained node to check ownership.
 *
 * Copyright (c) Citus Data, Inc.
 *
 *-------------------------------------------------------------------------
 */

#include "postgres.h"
#include "miscadmin.h"

#include "catalog/objectaddress.h"
#include "catalog/pg_type.h"
#include "distributed/citus_ruleutils.h"
#include "distributed/metadata/distobject.h"
#include "distributed/pg_version_constants.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "parser/parse_type.h"

static List * textarray_to_strvaluelist(ArrayType *arr);

/* It is defined on PG >= 13 versions by default */
#if PG_VERSION_NUM < PG_VERSION_13
	#define TYPALIGN_INT 'i'
#endif

/*
 * Get the object address. If accessCheck is true, access of the user on the object
 * is checked and if it is not the current user function will error out.
 *
 * This function is mostly copied from pg_get_object_address of the PG code. We need
 * to copy that function to use intermediate data types to check acl or ownership.
 */
ObjectAddress
PgGetObjectAddress(char *ttype, ArrayType *namearr, ArrayType *argsarr, bool accessCheck)
{
	List *name = NIL;
	TypeName *typename = NULL;
	List *args = NIL;
	Node *objnode = NULL;
	Relation relation;

	/* Decode object type, raise error if unknown */
	int itype = read_objtype_from_string(ttype);
	if (itype < 0)
	{
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("unsupported object type \"%s\"", ttype)));
	}
	ObjectType type = (ObjectType) itype;

	/*
	 * Convert the text array to the representation appropriate for the given
	 * object type.  Most use a simple string Values list, but there are some
	 * exceptions.
	 */
	if (type == OBJECT_TYPE || type == OBJECT_DOMAIN || type == OBJECT_CAST ||
		type == OBJECT_TRANSFORM || type == OBJECT_DOMCONSTRAINT)
	{
		Datum *elems;
		bool *nulls;
		int nelems;

		deconstruct_array(namearr, TEXTOID, -1, false, TYPALIGN_INT,
						  &elems, &nulls, &nelems);
		if (nelems != 1)
		{
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("name list length must be exactly %d", 1)));
		}
		if (nulls[0])
		{
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("name or argument lists may not contain nulls")));
		}
		typename = typeStringToTypeName(TextDatumGetCString(elems[0]));
	}
	else if (type == OBJECT_LARGEOBJECT)
	{
		Datum *elems;
		bool *nulls;
		int nelems;

		deconstruct_array(namearr, TEXTOID, -1, false, TYPALIGN_INT,
						  &elems, &nulls, &nelems);
		if (nelems != 1)
		{
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("name list length must be exactly %d", 1)));
		}
		if (nulls[0])
		{
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("large object OID may not be null")));
		}
		objnode = (Node *) makeFloat(TextDatumGetCString(elems[0]));
	}
	else
	{
		name = textarray_to_strvaluelist(namearr);
		if (list_length(name) < 1)
		{
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("name list length must be at least %d", 1)));
		}
	}

	/*
	 * If args are given, decode them according to the object type.
	 */
	if (type == OBJECT_AGGREGATE ||
		type == OBJECT_FUNCTION ||
		type == OBJECT_PROCEDURE ||
		type == OBJECT_ROUTINE ||
		type == OBJECT_OPERATOR ||
		type == OBJECT_CAST ||
		type == OBJECT_AMOP ||
		type == OBJECT_AMPROC)
	{
		/* in these cases, the args list must be of TypeName */
		Datum *elems;
		bool *nulls;
		int nelems;
		int i;

		deconstruct_array(argsarr, TEXTOID, -1, false,
						  TYPALIGN_INT,
						  &elems, &nulls, &nelems);

		args = NIL;
		for (i = 0; i < nelems; i++)
		{
			if (nulls[i])
			{
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
						 errmsg("name or argument lists may not contain nulls")));
			}
			args = lappend(args,
						   typeStringToTypeName(TextDatumGetCString(elems[i])));
		}
	}
	else
	{
		/* For all other object types, use string Values */
		args = textarray_to_strvaluelist(argsarr);
	}

	/*
	 * get_object_address is pretty sensitive to the length of its input
	 * lists; check that they're what it wants.
	 */
	switch (type)
	{
		case OBJECT_DOMCONSTRAINT:
		case OBJECT_CAST:
		case OBJECT_USER_MAPPING:
		case OBJECT_PUBLICATION_REL:
		case OBJECT_DEFACL:
		case OBJECT_TRANSFORM:
		{
			if (list_length(args) != 1)
			{
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
						 errmsg("argument list length must be exactly %d", 1)));
			}
			break;
		}

		case OBJECT_OPFAMILY:
		case OBJECT_OPCLASS:
		{
			if (list_length(name) < 2)
			{
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
						 errmsg("name list length must be at least %d", 2)));
			}
			break;
		}

		case OBJECT_AMOP:
		case OBJECT_AMPROC:
		{
			if (list_length(name) < 3)
			{
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
						 errmsg("name list length must be at least %d", 3)));
			}

			if (list_length(args) != 2)
			{
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
						 errmsg("argument list length must be exactly %d", 2)));
			}
			break;
		}

		case OBJECT_OPERATOR:
		{
			if (list_length(args) != 2)
			{
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
						 errmsg("argument list length must be exactly %d", 2)));
			}
			break;
		}

		default:
		{
			break;
		}
	}

	/*
	 * Now build the Node type that get_object_address() expects for the given
	 * type.
	 */
	switch (type)
	{
		case OBJECT_TABLE:
		case OBJECT_SEQUENCE:
		case OBJECT_VIEW:
		case OBJECT_MATVIEW:
		case OBJECT_INDEX:
		case OBJECT_FOREIGN_TABLE:
		case OBJECT_COLUMN:
		case OBJECT_ATTRIBUTE:
		case OBJECT_COLLATION:
		case OBJECT_CONVERSION:
		case OBJECT_STATISTIC_EXT:
		case OBJECT_TSPARSER:
		case OBJECT_TSDICTIONARY:
		case OBJECT_TSTEMPLATE:
		case OBJECT_TSCONFIGURATION:
		case OBJECT_DEFAULT:
		case OBJECT_POLICY:
		case OBJECT_RULE:
		case OBJECT_TRIGGER:
		case OBJECT_TABCONSTRAINT:
		case OBJECT_OPCLASS:
		case OBJECT_OPFAMILY:
		{
			objnode = (Node *) name;
			break;
		}

		case OBJECT_ACCESS_METHOD:
		case OBJECT_DATABASE:
		case OBJECT_EVENT_TRIGGER:
		case OBJECT_EXTENSION:
		case OBJECT_FDW:
		case OBJECT_FOREIGN_SERVER:
		case OBJECT_LANGUAGE:
		case OBJECT_PUBLICATION:
		case OBJECT_ROLE:
		case OBJECT_SCHEMA:
		case OBJECT_SUBSCRIPTION:
		case OBJECT_TABLESPACE:
		{
			if (list_length(name) != 1)
			{
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
						 errmsg("name list length must be exactly %d", 1)));
			}
			objnode = linitial(name);
			break;
		}

		case OBJECT_TYPE:
		case OBJECT_DOMAIN:
		{
			objnode = (Node *) typename;
			break;
		}

		case OBJECT_CAST:
		case OBJECT_DOMCONSTRAINT:
		case OBJECT_TRANSFORM:
		{
			objnode = (Node *) list_make2(typename, linitial(args));
			break;
		}

		case OBJECT_PUBLICATION_REL:
		{
			objnode = (Node *) list_make2(name, linitial(args));
			break;
		}

		case OBJECT_USER_MAPPING:
		{
			objnode = (Node *) list_make2(linitial(name), linitial(args));
			break;
		}

		case OBJECT_DEFACL:
		{
			objnode = (Node *) lcons(linitial(args), name);
			break;
		}

		case OBJECT_AMOP:
		case OBJECT_AMPROC:
		{
			objnode = (Node *) list_make2(name, args);
			break;
		}

		case OBJECT_FUNCTION:
		case OBJECT_PROCEDURE:
		case OBJECT_ROUTINE:
		case OBJECT_AGGREGATE:
		case OBJECT_OPERATOR:
		{
			ObjectWithArgs *owa = makeNode(ObjectWithArgs);

			owa->objname = name;
			owa->objargs = args;
			objnode = (Node *) owa;
			break;
		}

		case OBJECT_LARGEOBJECT:
		{
			/* already handled above */
			break;
		}

			/* no default, to let compiler warn about missing case */
	}

	if (objnode == NULL)
	{
		elog(ERROR, "unrecognized object type: %d", type);
	}

	ObjectAddress addr = get_object_address(type, objnode,
											&relation, AccessShareLock, false);

	/* CITUS CODE BEGIN */

	if (accessCheck)
	{
		Oid userId = GetUserId();
		AclMode aclMaskResult = 0;
		Oid idToCheck = InvalidOid;

		switch (type)
		{
			case OBJECT_ACCESS_METHOD:
			{
				if (IsObjectAddressOwnedByExtension(&addr, NULL))
				{
					elog(ERROR,
						 "Current user does not have required access privileges on access method %d with type %d",
						 addr.objectId, type);
				}
				aclMaskResult = 1;
				break;
			}

			case OBJECT_SCHEMA:
			{
				idToCheck = addr.objectId;
				aclMaskResult = pg_namespace_aclmask(idToCheck, userId, ACL_USAGE |
													 ACL_CONNECT | ACL_INSERT |
													 ACL_SELECT, ACLMASK_ANY);
				break;
			}

			case OBJECT_FUNCTION:
			case OBJECT_PROCEDURE:
			case OBJECT_AGGREGATE:
			{
				idToCheck = addr.objectId;
				aclMaskResult = pg_proc_aclmask(idToCheck, userId, ACL_EXECUTE,
												ACLMASK_ANY);
				break;
			}

			case OBJECT_DATABASE:
			{
				idToCheck = addr.objectId;
				aclMaskResult = pg_database_aclmask(idToCheck, userId, ACL_CONNECT,
													ACLMASK_ANY);
				break;
			}

			case OBJECT_ROLE:
			{
				if (!(addr.objectId == CitusExtensionOwner()))
				{
					elog(ERROR,
						 "Current user does not have required access privileges on role %d with type %d",
						 addr.objectId, type);
				}
				aclMaskResult = 1;
				break;
			}

			case OBJECT_TYPE:
			{
				idToCheck = addr.objectId;
				aclMaskResult = pg_type_aclmask(idToCheck, userId, ACL_USAGE,
												ACLMASK_ANY);
				break;
			}

			case OBJECT_SEQUENCE:
			case OBJECT_TABLE:
			{
				idToCheck = RelationGetRelid(relation);
				aclMaskResult = pg_class_aclmask(idToCheck, userId, ACL_SELECT,
												 ACLMASK_ANY);
				break;
			}

			case OBJECT_COLLATION:
			case OBJECT_EXTENSION:
			{
				aclMaskResult = 1;
				break;
			}

			default:
			{
				elog(ERROR, "%d object type is not supported within object propagation",
					 type);
				break;
			}
		}

		if (aclMaskResult == ACL_NO_RIGHTS)
		{
			elog(ERROR,
				 "Current user does not have required access privileges on %d with type id %d",
				 idToCheck, type);
		}
	}

	/* CITUS CODE END */

	/* We don't need the relcache entry, thank you very much */
	if (relation)
	{
		relation_close(relation, AccessShareLock);
	}

	/* CITUS CODE BEGIN */
	return addr;

	/* CITUS CODE END */
}


/*
 * Copied from PG code.
 *
 * Convert an array of TEXT into a List of string Values, as emitted by the
 * parser, which is what get_object_address uses as input.
 */
static List *
textarray_to_strvaluelist(ArrayType *arr)
{
	Datum *elems;
	bool *nulls;
	int nelems;
	List *list = NIL;
	int i;

	deconstruct_array(arr, TEXTOID, -1, false, TYPALIGN_INT,
					  &elems, &nulls, &nelems);

	for (i = 0; i < nelems; i++)
	{
		if (nulls[i])
		{
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("name or argument lists may not contain nulls")));
		}
		list = lappend(list, makeString(TextDatumGetCString(elems[i])));
	}

	return list;
}
