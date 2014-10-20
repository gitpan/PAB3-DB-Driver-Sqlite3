#include <EXTERN.h>
#include <perl.h>
#include <XSUB.h>

//#include "ppport.h"

#include <sqlite3.h>
#include "my_sqlite3.h"

MODULE = PAB3::DB::Driver::Sqlite3		PACKAGE = PAB3::DB::Driver::Sqlite3

BOOT:
{
	MY_CXT_INIT;
#ifdef USE_THREADS
	//MUTEX_INIT( &MY_CXT.share_lock );
#endif
	my_init();
}

#define __PACKAGE__ "PAB3::DB::Driver::Sqlite3"


#/******************************************************************************
# * _open( db [, client_flag] )
# ******************************************************************************/

UV
_open( db, client_flag = 0 )
const char *db
unsigned long client_flag
PREINIT:
	dMY_CXT;
	sqlite3 *con;
	MY_CON *rcon;
	int r, l;
	const char *error;
CODE:
	r = sqlite3_open( db, &con );
	if( r == SQLITE_OK ) {
		rcon = my_con_add( con, get_current_thread_id() );
		if( db ) {
			l = strlen( db );
			New( 1, rcon->db, l + 1, char );
			Copy( db, rcon->db, l + 1, char );
		}
		RETVAL = (UV) rcon;
	}
	else {
		if( con != NULL ) {
			error = sqlite3_errmsg( con );
			my_strcpy( MY_CXT.last_error, error );
			MY_CXT.last_errno = sqlite3_errcode( con );
			sqlite3_close( con );
		}
		RETVAL = 0;
	}
OUTPUT:
	RETVAL


#/******************************************************************************
# * close( [linkid] )
# ******************************************************************************/

void
close( linkid = 0 )
UV linkid
CODE:
	switch( my_get_type( &linkid ) ) {
	case MY_TYPE_CON:
		my_con_rem( (MY_CON *) linkid );
		break;
	case MY_TYPE_RES:
		my_result_rem( (MY_RES *) linkid );
		break;
	case MY_TYPE_STMT:
		my_stmt_rem( (MY_STMT *) linkid );
		break;
	}


#/******************************************************************************
# * reconnect( [linkid] )
# ******************************************************************************/

UV
reconnect( linkid = 0 )
UV linkid
CODE:
	if( ( linkid = my_verify_linkid( linkid ) ) )
		RETVAL = 1;
	else
		RETVAL = 0;
OUTPUT:
	RETVAL


#/******************************************************************************
# * query( [linkid, ] sql )
# ******************************************************************************/

UV
query( ... )
PREINIT:
	const char *sql;
	UV linkid = 0;
	MY_CON *con;
	MY_RES *res;
	int r, itemp = 0;
CODE:
	switch( items ) {
	case 2:
		linkid = (UV) SvUV( ST( itemp ) );
		itemp ++;
	case 1:
		sql = (const char *) SvPV_nolen( ST( itemp ) );
		break;
	default:	
		Perl_croak( aTHX_ "Usage: " __PACKAGE__ "::query(linkid = 0, query)" );
	}
	con = (MY_CON *) my_verify_linkid( linkid );
	if( con == NULL ) goto error;
	res = my_result_add( con );
	r = sqlite3_exec( con->con, sql, &my_callback, res, 0 );
	if( r == SQLITE_OK ) {
		if( res->is_valid ) {
			res->current_row = res->data_cursor;
			RETVAL = (long) res;
		}
		else {
			my_result_rem( res );
			RETVAL = 1;
		}
	}
	else {
		my_result_rem( res );
		goto error;
	}
	goto exit;
error:
	RETVAL = 0;
exit:
OUTPUT:
	RETVAL


#/******************************************************************************
# * prepare( [linkid, ] sql )
# ******************************************************************************/

UV
prepare( ... )
PREINIT:
	const char *sql;
	UV linkid = 0;
	MY_CON *con;
	sqlite3_stmt *pStmt;
//	const char *pzTail;
	int r, itemp = 0;
CODE:
	switch( items ) {
	case 2:
		linkid = (UV) SvUV( ST( itemp ) );
		itemp ++;
	case 1:
		sql = (const char *) SvPV_nolen( ST( itemp ) );
		break;
	default:	
		Perl_croak( aTHX_ "Usage: " __PACKAGE__ "::prepare(linkid = 0, query)" );
	}
	con = (MY_CON *) my_verify_linkid( linkid );
	if( con == NULL ) goto error;
	r = sqlite3_prepare_v2( con->con, sql, strlen( sql ), &pStmt, NULL );
	if( r != SQLITE_OK ) goto error;
	RETVAL = (UV) my_stmt_add( con, pStmt );
	goto exit;
error:
	RETVAL = 0;
exit:
OUTPUT:
	RETVAL


#/******************************************************************************
# * bind_param( stmtid, p_num, val )
# ******************************************************************************/

int
bind_param( stmtid, p_num, val, type = 0 )
UV stmtid
unsigned long p_num
SV *val
char type
CODE:
	if( ! my_stmt_exists( stmtid ) )
		RETVAL = 0;
	else
		RETVAL = my_stmt_bind_param( (MY_STMT *) stmtid, p_num, val, type ) == SQLITE_OK;
OUTPUT:
	RETVAL


#/******************************************************************************
# * execute( stmtid, [*params] )
# ******************************************************************************/

UV
execute( stmtid, ... )
UV stmtid
PREINIT:
	MY_STMT *stmt;
	MY_RES *res;
	MY_ROWS *row;
	DWORD i, columns, l;
	const char *p1;
CODE:
	if( ! my_stmt_exists( stmtid ) ) goto error;
	stmt = (MY_STMT *) stmtid;
	if( stmt->res != NULL ) {
		if( stmt->res->is_valid == 2 )
			my_result_rem( stmt->res );
		else
			stmt->res->stmt = NULL;
		sqlite3_reset( stmt->stmt );
	}
	for( i = 1; i < MIN( items, stmt->param_count + 1 ); i ++ ) {
		RETVAL = my_stmt_bind_param( stmt, i, ST( i ), 0 );
		if( RETVAL != SQLITE_OK ) goto error;
	}
	RETVAL = sqlite3_step( stmt->stmt ); 
	switch( RETVAL ) {
	case SQLITE_ROW:
		// save result
		//Newz( 1, res, 1, MY_RES );
		res = my_result_add( stmt->con );
		res->con = stmt->con;
		res->stmt = stmt;
		columns = res->numfields = sqlite3_column_count( stmt->stmt );
		Newz( 1, res->fields, columns, MY_FIELD );
		for( i = 0; i < columns; i ++ ) {
			p1 = sqlite3_column_name( stmt->stmt, i );
			res->fields[i].name_length = strlen( p1 );
			New( 1, res->fields[i].name, res->fields[i].name_length + 1, char );
			memcpy( res->fields[i].name, p1, res->fields[i].name_length + 1 );
		}
		do {
			New( 1, row, 1, MY_ROWS );
			New( 1, row->types, columns, char );
			New( 1, row->lengths, columns, DWORD );
			New( 1, row->data, columns, char* );
			for( i = 0; i < columns; i ++ ) {
				l = sqlite3_column_bytes( stmt->stmt, i );
				row->lengths[i] = l;
				row->types[i] = sqlite3_column_type( stmt->stmt, i );
				switch( row->types[i] ) {
				case SQLITE_INTEGER:
					// save as text
					New( 1, row->data[i], l, char );
					memcpy( row->data[i], sqlite3_column_text( stmt->stmt, i ), l );
					row->types[i] = SQLITE_TEXT;
					//row->data[i] = malloc( sizeof( int ) );
					//*((int *) row->data[i]) = sqlite3_column_int( stmt->stmt, i );
					break;
				case SQLITE_FLOAT:
					row->data[i] = malloc( sizeof( double ) );
					*((double *) row->data[i]) = sqlite3_column_double( stmt->stmt, i );
					break;
				case SQLITE_TEXT:
					New( 1, row->data[i], l, char );
					memcpy( row->data[i], sqlite3_column_text( stmt->stmt, i ), l );
					break;
				case SQLITE_BLOB:
					New( 1, row->data[i], l, char );
					memcpy( row->data[i], sqlite3_column_blob( stmt->stmt, i ), l );
					break;
				case SQLITE_NULL:
					row->data[i] = NULL;
					break;
				}
			}
			if( ! res->numrows ) {
				row->prev = row->next = NULL;
				res->data_cursor = row;
				res->current_row = row;
				res->is_valid = 1;
			}
			else {
				res->current_row->next = row;
				row->prev = res->current_row;
				row->next = NULL;
				res->current_row = row;
			}
			res->numrows ++;
			RETVAL = sqlite3_step( stmt->stmt ); 
		} while( RETVAL == SQLITE_ROW );
		res->current_row = res->data_cursor;
		stmt->res = res;
		RETVAL = (UV) res;
		goto exit;
	case SQLITE_DONE:
		RETVAL = 1;
		goto exit;
	default:
		sqlite3_finalize( stmt->stmt );
		goto error;
	}
error:
	RETVAL = 0;
exit:
OUTPUT:
	RETVAL


#/******************************************************************************
# * free_result( resid )
# ******************************************************************************/

int
free_result( resid )
UV resid
CODE:
	switch( my_stmt_or_res( resid ) ) {
	case MY_TYPE_RES:
		if( ((MY_RES *) resid)->stmt == NULL ) {
			my_result_rem( (MY_RES *) resid );
		}
		else {
			// bind result to statement
			((MY_RES *) resid)->is_valid = 2;
		}
		RETVAL = 1;
		break;
	case MY_TYPE_STMT:
		my_stmt_rem( (MY_STMT *) resid );
		RETVAL = 1;
		break;
	default:
		RETVAL = 0;
	}
OUTPUT:
	RETVAL


#/******************************************************************************
# * num_fields( resid )
# ******************************************************************************/

unsigned long
num_fields( resid )
long resid
CODE:
	switch( my_stmt_or_res( resid ) ) {
	case MY_TYPE_RES:
		RETVAL = ( (MY_RES *) resid )->numfields;
		break;
	case MY_TYPE_STMT:
		RETVAL = ( (MY_STMT *) resid )->res != NULL
			? ( (MY_STMT *) resid )->res->numfields : 0;
		break;
	default:
		RETVAL = 0;
	}
OUTPUT:
	RETVAL


#/******************************************************************************
# * num_rows( resid )
# ******************************************************************************/

unsigned long
num_rows( resid )
UV resid
CODE:
	switch( my_stmt_or_res( resid ) ) {
	case MY_TYPE_RES:
		RETVAL = ( (MY_RES *) resid )->numrows;
		break;
	case MY_TYPE_STMT:
		RETVAL = ( (MY_STMT *) resid )->res != NULL
			? ( (MY_STMT *) resid )->res->numrows : 0;
		break;
	default:
		RETVAL = 0;
	}
OUTPUT:
	RETVAL


#/******************************************************************************
# * fetch_names( resid )
# ******************************************************************************/

void
fetch_names( resid )
UV resid
PREINIT:
	MY_RES *res;
	DWORD i;
PPCODE:
	switch( my_stmt_or_res( resid ) ) {
	case MY_TYPE_RES:
		res = (MY_RES *) resid;
		break;
	case MY_TYPE_STMT:
		res = ((MY_STMT *) resid)->res;
		if( res == NULL ) goto exit;
		break;
	default:
		goto exit;
	}
	for( i = 0; i < res->numfields; i ++ )
		XPUSHs( sv_2mortal( newSVpvn( res->fields[i].name, res->fields[i].name_length ) ) );	
exit:
	{}


#/******************************************************************************
# * fetch_field( resid [, offset] )
# ******************************************************************************/

void
fetch_field( resid, offset = -1 )
UV resid
long offset
PREINIT:
	MY_RES *res;
	MY_STMT *stmt;
	DWORD i;
	const char *table, *catalog, *dt, *cs;
	int nn, pk, ai, r;
PPCODE:
	switch( my_stmt_or_res( resid ) ) {
	case MY_TYPE_RES:
		res = (MY_RES *) resid;
		stmt = res->stmt;
		break;
	case MY_TYPE_STMT:
		stmt = (MY_STMT *) resid;
		res = stmt->res;
		if( res == NULL ) goto exit;
		break;
	default:
		goto exit;
	}
	if( offset >= 0 ) {
		if( offset >= res->numfields )
			res->fieldpos = res->numfields - 1;
		else
			res->fieldpos = offset;
	}
	i = res->fieldpos;
	if( i >= res->numfields ) goto exit;
	XPUSHs( sv_2mortal( newSVpvn( "name", 4 ) ) );
	XPUSHs( sv_2mortal( newSVpvn( res->fields[i].name, res->fields[i].name_length ) ) );
#ifdef SQLITE_ENABLE_COLUMN_METADATA
	if( stmt != NULL ) {
		table = sqlite3_column_table_name( stmt->stmt, i );
		XPUSHs( sv_2mortal( newSVpvn( "table", 5 ) ) );
		XPUSHs( sv_2mortal( newSVpvn( table, strlen( table ) ) ) );
		catalog = sqlite3_column_database_name( stmt->stmt, i );
		XPUSHs( sv_2mortal( newSVpvn( "catalog", 7 ) ) );
		XPUSHs( sv_2mortal( newSVpvn( catalog, strlen( catalog ) ) ) );
		r = sqlite3_table_column_metadata(
			stmt->con->con, catalog, table, res->fields[i].name,
			&dt, &cs, &nn, &pk, &ai
		);
		if( r == SQLITE_OK ) {
			XPUSHs( sv_2mortal( newSVpvn( "nullable", 8 ) ) );
			XPUSHs( sv_2mortal( newSViv( ! nn ) ) );
			XPUSHs( sv_2mortal( newSVpvn( "primary", 7 ) ) );
			XPUSHs( sv_2mortal( newSViv( pk ) ) );
			XPUSHs( sv_2mortal( newSVpvn( "identity", 8 ) ) );
			XPUSHs( sv_2mortal( newSViv( ai ) ) );
		}
	}
#endif
exit:
	{}


#/******************************************************************************
# * field_seek( resid [, offset] )
# ******************************************************************************/

UV
field_seek( resid, offset = 0 )
UV resid
long offset
PREINIT:
	MY_RES *res;
CODE:
	RETVAL = 0;
	switch( my_stmt_or_res( resid ) ) {
	case MY_TYPE_RES:
		res = (MY_RES *) resid;
		break;
	case MY_TYPE_STMT:
		res = ((MY_STMT *) resid)->res;
		if( res == NULL ) goto exit;
		break;
	default:
		goto exit;
	}
	RETVAL = res->fieldpos;
	if( offset < 0 )
		res->fieldpos = 0;
	else if( offset >= res->numfields )
		res->fieldpos = res->numfields - 1;
	else
		res->fieldpos = offset;
exit:
OUTPUT:
	RETVAL


#/******************************************************************************
# * fetch_row( resid )
# ******************************************************************************/

void
fetch_row( resid )
UV resid
PREINIT:
	MY_RES *res;
	MY_ROWS *row;
	unsigned long i;
PPCODE:
	switch( my_stmt_or_res( resid ) ) {
	case MY_TYPE_RES:
		res = (MY_RES *) resid;
		break;
	case MY_TYPE_STMT:
		res = ((MY_STMT *) resid)->res;
		if( res == NULL ) goto exit;
		break;
	default:
		goto exit;
	}
	row = res->current_row;
	if( row == NULL ) goto exit;
	EXTEND( SP, res->numfields );
	for( i = 0; i < res->numfields; i ++ ) {
		switch( row->types[i] ) {
		case SQLITE_INTEGER:
			XPUSHs( sv_2mortal( newSViv( *((int*) row->data[i]) ) ) );
			break;
		case SQLITE_FLOAT:
			XPUSHs( sv_2mortal( newSVnv( *((double*) row->data[i]) ) ) );
			break;
		case SQLITE_TEXT:
			XPUSHs( sv_2mortal( newSVpvn( row->data[i], row->lengths[i] ) ) );
			break;
		case SQLITE_BLOB:
			XPUSHs( sv_2mortal( newSVpvn( row->data[i], row->lengths[i] ) ) );
			break;
		case SQLITE_NULL:
			XPUSHs( &PL_sv_undef );
			break;
		}
	}
	res->current_row = row->next;
	res->rowpos ++;
exit:
	{}


#/******************************************************************************
# * fetch_col( resid )
# ******************************************************************************/

void
fetch_col( resid )
UV resid
PREINIT:
	MY_RES *res;
	MY_ROWS *row;
	unsigned long i;
PPCODE:
	switch( my_stmt_or_res( resid ) ) {
	case MY_TYPE_RES:
		res = (MY_RES *) resid;
		break;
	case MY_TYPE_STMT:
		res = ((MY_STMT *) resid)->res;
		if( res == NULL ) goto exit;
		break;
	default:
		goto exit;
	}
	EXTEND( SP, res->numrows );
	row = res->data_cursor;
	while( row ) {
		switch( row->types[0] ) {
		case SQLITE_INTEGER:
			XPUSHs( sv_2mortal( newSViv( *((int*) row->data[0]) ) ) );
			break;
		case SQLITE_FLOAT:
			XPUSHs( sv_2mortal( newSVnv( *((double*) row->data[0]) ) ) );
			break;
		case SQLITE_TEXT:
			XPUSHs( sv_2mortal( newSVpvn( row->data[i], row->lengths[0] ) ) );
			break;
		case SQLITE_BLOB:
			XPUSHs( sv_2mortal( newSVpvn( row->data[i], row->lengths[0] ) ) );
			break;
		case SQLITE_NULL:
			XPUSHs( &PL_sv_undef );
			break;
		}
		row = row->next;
	}
	res->rowpos = res->numrows;
	res->current_row = NULL;
exit:
	{}


#/******************************************************************************
# * fetch_hash( resid )
# ******************************************************************************/

void
fetch_hash( resid )
UV resid
PREINIT:
	MY_RES *res;
	MY_ROWS *row;
	DWORD i;
PPCODE:
	switch( my_stmt_or_res( resid ) ) {
	case MY_TYPE_RES:
		res = (MY_RES *) resid;
		break;
	case MY_TYPE_STMT:
		res = ((MY_STMT *) resid)->res;
		if( res == NULL ) goto exit;
		break;
	default:
		goto exit;
	}
	row = res->current_row;
	if( row == NULL ) goto exit;
	EXTEND( SP, res->numfields );
	for( i = 0; i < res->numfields; i ++ ) {
		XPUSHs( sv_2mortal( newSVpvn( res->fields[i].name, res->fields[i].name_length ) ) );	
		switch( row->types[i] ) {
		case SQLITE_INTEGER:
			XPUSHs( sv_2mortal( newSViv( *((int*) row->data[i]) ) ) );
			break;
		case SQLITE_FLOAT:
			XPUSHs( sv_2mortal( newSVnv( *((double*) row->data[i]) ) ) );
			break;
		case SQLITE_TEXT:
			XPUSHs( sv_2mortal( newSVpvn( row->data[i], row->lengths[i] ) ) );
			break;
		case SQLITE_BLOB:
			XPUSHs( sv_2mortal( newSVpvn( row->data[i], row->lengths[i] ) ) );
			break;
		case SQLITE_NULL:
			XPUSHs( &PL_sv_undef );
			break;
		}
	}
	res->current_row = row->next;
	res->rowpos ++;
exit:
	{}


#/******************************************************************************
# * fetch_lengths( resid )
# ******************************************************************************/

void
fetch_lengths( resid )
UV resid
PREINIT:
	MY_RES *res;
	MY_ROWS *row;
	DWORD i;
PPCODE:
	switch( my_stmt_or_res( resid ) ) {
	case MY_TYPE_RES:
		res = (MY_RES *) resid;
		break;
	case MY_TYPE_STMT:
		res = ((MY_STMT *) resid)->res;
		if( res == NULL ) goto exit;
		break;
	default:
		goto exit;
	}
	row = res->current_row;
	if( row == NULL ) goto exit;
	EXTEND( SP, res->numfields );
	for( i = 0; i < res->numfields; i ++ ) {
		XPUSHs( sv_2mortal( newSVuv( row->lengths[i] ) ) );	
	}
exit:
	{}


#/******************************************************************************
# * row_tell( resid )
# ******************************************************************************/

unsigned long
row_tell( resid )
UV resid
CODE:
	switch( my_stmt_or_res( resid ) ) {
	case MY_TYPE_RES:
		RETVAL = ( (MY_RES *) resid )->rowpos;
		break;
	case MY_TYPE_STMT:
		RETVAL = ((MY_STMT *) resid)->res != NULL
			? ((MY_STMT *) resid)->res->rowpos : 0;
		break;
	default:
		RETVAL = 0;
	}
OUTPUT:
	RETVAL


#/******************************************************************************
# * row_seek( resid, offset )
# ******************************************************************************/

long
row_seek( resid, offset = 0 )
UV resid
long offset
PREINIT:
	MY_RES *res;
	MY_ROWS *row;
	unsigned long remaining;
CODE:
	RETVAL = -1;
	switch( my_stmt_or_res( resid ) ) {
	case MY_TYPE_RES:
		res = (MY_RES *) resid;
		break;
	case MY_TYPE_STMT:
		res = ((MY_STMT *) resid)->res;
		if( res == NULL ) goto exit;
		break;
	default:
		goto exit;
	}
	RETVAL = res->rowpos;
	if( offset < 0 )
		res->rowpos = 0;
	else if( offset >= res->numrows )
		res->rowpos = res->numrows - 1;
	else
		res->rowpos = offset;
	if( abs( offset - res->rowpos ) < offset ) {
		row = res->current_row;
		if( offset < res->rowpos ) {
			remaining = res->rowpos - offset;
			while( remaining && row->prev ) {
				row = row->prev;
				res->rowpos --;
				remaining --;
			}
		}
		else {
			remaining = offset - res->rowpos;
			while( remaining && row->next ) {
				row = row->next;
				res->rowpos ++;
				remaining --;
			}
		}
	}
	else {
		row = res->data_cursor;
		res->rowpos = 0;
		remaining = offset;
		while( remaining && row->next ) {
			row = row->next;
			res->rowpos ++;
			remaining --;
		}
	}
	res->current_row = row;
exit:
OUTPUT:
	RETVAL


#/******************************************************************************
# * insert_id( [linkid [, field [, table [, schema]]]] )
# ******************************************************************************/

UV
insert_id( linkid = 0, field = NULL, table = NULL, schema = NULL )
UV linkid
const char *field
const char *table
const char *schema
CODE:
	switch( my_stmt_or_con( &linkid ) ) {
	case MY_TYPE_CON:
		RETVAL = (UV) sqlite3_last_insert_rowid( ((MY_CON *) linkid)->con );
		break;
	case MY_TYPE_STMT:
		RETVAL = (UV) sqlite3_last_insert_rowid( ((MY_STMT *) linkid)->con->con );
		break;
	default:
		RETVAL = 0;
		break;
	}
OUTPUT:
	RETVAL


#/******************************************************************************
# * affected_rows( [linkid] )
# ******************************************************************************/

UV
affected_rows( linkid = 0 )
UV linkid
CODE:
	switch( my_stmt_or_con( &linkid ) ) {
	case MY_TYPE_CON:
		RETVAL = (UV) sqlite3_changes( ((MY_CON *) linkid)->con );
		break;
	case MY_TYPE_STMT:
		RETVAL = (UV) sqlite3_changes( ((MY_STMT *) linkid)->con->con );
		break;
	default:
		RETVAL = 0;
		break;
	}
OUTPUT:
	RETVAL


#/******************************************************************************
# * quote( val )
# ******************************************************************************/

SV *
quote( val )
const char *val
PREINIT:
	char *res = 0;
	int l, lmax, i, dp;
CODE:
	l = strlen( val );
	lmax = l * 2 + 3;
	New( 1, res, lmax, char );
	dp = 1;
	res[0] = '\'';
	for( i = 0; i < l; i ++ ) {
		if( val[i] == '\'' ) {
			res[dp ++] = '\'';
			res[dp ++] = '\'';
		}
		else {
			res[dp ++] = val[i];
		}
	}
	res[dp ++] = '\'';
	res[dp] = 0;
	ST(0) = newSVpvn( res, dp );
	sv_2mortal( ST(0) );
CLEANUP:
	Safefree( res );


#/******************************************************************************
# * quote_id( p1, ... )
# ******************************************************************************/

SV *
quote_id( p1, ... )
const char *p1
PREINIT:
	const char *str;
	char *res = 0;
	int i;
	unsigned long j, rlen, rpos;
	STRLEN len;
CODE:
	rlen = items * 127;
	New( 1, res, rlen, char );
	rpos = 0;
	for( i = 0; i < items; i ++ ) {
		len = SvLEN( ST(i) );
		str = (const char *) SvPV( ST(i), len );
		if( rpos + len * 2 > rlen ) {
			rlen = rpos + len * 2 + 3;
			Renew( res, rlen, char );
		}
		if( i > 0 ) res[rpos ++] = '.';
		if( i == items - 1 && len == 1 && str[0] == '*' ) {
			res[rpos ++] = '*';
		}
		else {
			res[rpos ++] = '"';
			for( j = 0; j < len; j ++ ) {
				if( str[j] == '"' ) {
					res[rpos ++] = '"';
					res[rpos ++] = '"';
				}
				else {
					res[rpos ++] = str[j];
				}
			}
			res[rpos ++] = '"';
		}
	}
	res[rpos] = '\0';
	ST(0) = sv_2mortal( newSVpvn( res, rpos ) );
CLEANUP:
	Safefree( res );


#/******************************************************************************
# * set_charset( charset [, linkid] )
# ******************************************************************************/

int
set_charset( ... )
PREINIT:
	const char *charset;
	UV linkid, itemp = 0;
	MY_CON *con;
CODE:
    if( items < 1 || items > 2 )
		Perl_croak( aTHX_ "Usage: " __PACKAGE__ "::set_charset(linkid = 0, charset)" );
	if( items > 1 ) {
		linkid = (UV) SvUV( ST( itemp ) );
		itemp ++;
	}
    charset = (const char *) SvPV_nolen( ST( itemp ) );
	con = (MY_CON *) my_verify_linkid( linkid );
	if( con == NULL ) goto error;
	RETVAL = 1;
	goto exit;
error:
	RETVAL = 0;
exit:
OUTPUT:
	RETVAL


#/******************************************************************************
# * get_charset( [linkid] )
# ******************************************************************************/

const char *
get_charset( linkid = 0 )
long linkid
CODE:
	RETVAL = "utf8";
OUTPUT:
	RETVAL


#/******************************************************************************
# * sql_limit( sql, length, limit [, offset] )
# ******************************************************************************/

char *
sql_limit( sql, length, limit, offset = -1 )
const char *sql
unsigned long length
long limit
long offset
PREINIT:
	char *res, *rp;
	const char *fc;
	long i, fl, fp;
CODE:
	if( sql ) {
		const char *find = "limit";
		fl = 4; fp = 4; fc = 0;
		for( i = length - 1; i >= 0; i -- ) {
			if( tolower( sql[i] ) == find[fp] ) {
				fp --;
				if( fp < 0 ) {
					while( i > 0 && sql[-- i] == '0' ) {}
					fc = &sql[i];
					break;
				}
			}
			else if( fp < fl ) {
				fp = fl;
			}
		}
		if( fc ) {
			New( 1, res, fc - sql + 22, char );
			strncpy( res, sql, fc - sql );
			rp = res + ( fc - sql );
		}
		else {
			New( 1, res, length + 22, char );
			strncpy( res, sql, length );
			rp = res + length;
		}
		if( offset >= 0 )
			sprintf( rp, " LIMIT %u, %u", offset, limit );
		else
			sprintf( rp, " LIMIT %u", limit );
	}
	else {
		res = 0;
	}
	RETVAL = res;
OUTPUT:
	RETVAL
CLEANUP:
	Safefree( res );


#/******************************************************************************
# * auto_commit( bool, [linkid] )
# ******************************************************************************/

int
auto_commit( linkid = 0, mode = 0 )
UV linkid
int mode
PREINIT:
	MY_CON *con;
	int r;
CODE:
	con = (MY_CON *) my_verify_linkid( linkid );
	if( con == NULL ) goto error;
	if( mode ) {
		if( ( con->my_flags & MYCF_AUTOCOMMIT ) == 0 ) {
			if( ( con->my_flags & MYCF_TRANSACTION ) != 0 ) {
				r = sqlite3_exec( con->con, "COMMIT TRANSACTION", 0, 0, 0 );
				if( r != SQLITE_OK ) goto error;
				con->my_flags ^= MYCF_TRANSACTION;
			}
			con->my_flags |= MYCF_AUTOCOMMIT;
		}
	}
	else {
		if( ( con->my_flags & MYCF_AUTOCOMMIT ) != 0 ) {
			if( ( con->my_flags & MYCF_TRANSACTION ) == 0 ) {
				r = sqlite3_exec( con->con, "BEGIN TRANSACTION", 0, 0, 0 );
				if( r != SQLITE_OK ) goto error;
				con->my_flags |= MYCF_TRANSACTION;
			}
			con->my_flags ^= MYCF_AUTOCOMMIT;
		}
	}
	RETVAL = 1;
	goto exit;
error:
	RETVAL = 0;
exit:
OUTPUT:
	RETVAL


#/******************************************************************************
# * begin_work( [linkid] )
# ******************************************************************************/

int
begin_work( linkid = 0 )
UV linkid
PREINIT:
	MY_CON *con;
	int r;
CODE:
	con = (MY_CON *) my_verify_linkid( linkid );
	if( con == NULL ) goto error;
	if( ( con->my_flags & MYCF_AUTOCOMMIT ) != 0
		&& ( con->my_flags & MYCF_TRANSACTION ) == 0
	) {
		r = sqlite3_exec( con->con, "BEGIN TRANSACTION", 0, 0, 0 );
		if( r != SQLITE_OK ) goto error;
		con->my_flags |= MYCF_TRANSACTION;
	}
	RETVAL = 1;
	goto exit;
error:
	RETVAL = 0;
exit:
OUTPUT:
	RETVAL


#/******************************************************************************
# * commit( [linkid] )
# ******************************************************************************/

int
commit( linkid = 0 )
UV linkid
PREINIT:
	MY_CON *con;
	int r;
CODE:
	con = (MY_CON *) my_verify_linkid( linkid );
	if( con == NULL ) goto error;
	if( ( con->my_flags & MYCF_TRANSACTION ) != 0 ) {
		r = sqlite3_exec( con->con, "COMMIT TRANSACTION", 0, 0, 0 );
		if( r != SQLITE_OK ) goto error;
		con->my_flags ^= MYCF_TRANSACTION;
		if( ( con->my_flags & MYCF_AUTOCOMMIT ) == 0 ) {
			r = sqlite3_exec( con->con, "BEGIN TRANSACTION", 0, 0, 0 );
			if( r != SQLITE_OK ) goto error;
			con->my_flags |= MYCF_TRANSACTION;
		}
	}
	RETVAL = 1;
	goto exit;
error:
	RETVAL = 0;
exit:
OUTPUT:
	RETVAL


#/******************************************************************************
# * rollback( [linkid] )
# ******************************************************************************/

int
rollback( linkid = 0 )
UV linkid
PREINIT:
	MY_CON *con;
	int r;
CODE:
	con = (MY_CON *) my_verify_linkid( linkid );
	if( con == NULL ) goto error;
	if( ( con->my_flags & MYCF_TRANSACTION ) != 0 ) {
		r = sqlite3_exec( con->con, "ROLLBACK TRANSACTION", 0, 0, 0 );
		if( r != SQLITE_OK ) goto error;
		con->my_flags ^= MYCF_TRANSACTION;
		if( ( con->my_flags & MYCF_AUTOCOMMIT ) == 0 ) {
			r = sqlite3_exec( con->con, "BEGIN TRANSACTION", 0, 0, 0 );
			if( r != SQLITE_OK ) goto error;
			con->my_flags |= MYCF_TRANSACTION;
		}
	}
	RETVAL = 1;
	goto exit;
error:
	RETVAL = 0;
exit:
OUTPUT:
	RETVAL


#/******************************************************************************
# * show_catalogs( [linkid [, wild]] )
# ******************************************************************************/

void
show_catalogs( linkid = 0, wild = NULL )
UV linkid
const char *wild
PREINIT:
	int r;
	MY_CON *con;
PPCODE:
	int _intcb( void *arg, int columns, char **data, char **names ) {
		if( columns > 1 )
			XPUSHs( sv_2mortal( newSVpvn( data[1], strlen( data[1] ) ) ) );
		return 0;
	}
	
	con = (MY_CON *) my_verify_linkid( linkid );
	if( con == NULL ) goto error;
	
	r = sqlite3_exec( con->con, "PRAGMA database_list", &_intcb, 0, 0 );
error:
	{}


#/******************************************************************************
# * show_tables( [linkid, [schema [, db [, wild]]]] )
# ******************************************************************************/

void
show_tables( linkid = 0, schema = NULL, db = NULL, wild = NULL )
UV linkid
const char *db
const char *schema
const char *wild
PREINIT:
	MY_CON *con;
	AV *av;
	char sql[256], *p1;
PPCODE:
	// TABLE, SCHEMA, DB, TYPE
	
	int _intcb( void *arg, int columns, char **data, char **names ) {
		/*
		int i;
		for( i = 0; i < columns; i ++ ) {
			printf( "%s => %s ", names[i], data[i] );
		}
		printf( "\n" );
		*/
		av = (AV *) sv_2mortal( (SV *) newAV() );
		av_push( av, newSVpvn( data[2], strlen( data[2] ) ) );
		av_push( av, &PL_sv_undef );
		if( db == NULL )
			av_push( av, newSVpvn( "main", 4 ) );
		else
			av_push( av, newSVpvn( db, strlen( db ) ) );
		av_push( av, newSVpvn( data[0], strlen( data[0] ) ) );
		XPUSHs( newRV( (SV *) av ) );
		return 0;
	}

	con = (MY_CON *) my_verify_linkid( linkid );
	if( con == NULL ) goto error;
	
	p1 = my_strcpy( sql, "SELECT * FROM " );
	if( db != NULL ) {
		p1 = my_strcpy( p1, db );
		*p1 ++ = '.';
	}
	p1 = my_strcpy( p1, "SQLITE_MASTER WHERE " );
	if( wild != NULL ) {
		p1 = my_strcpy( p1, "type='" );
		p1 = my_strcpy( p1, wild );
		p1 = my_strcpy( p1, "'" );
	}
	else {
		p1 = my_strcpy( p1, "type='table' or type='view'" );
	}
	sqlite3_exec( con->con, sql, &_intcb, 0, 0 );
error:
	{}


#/******************************************************************************
# * show_fields( [linkid, ] table [, schema [, db [, wild]]]] )
# ******************************************************************************/

void
show_fields( ... )
PREINIT:
	UV linkid = 0;
	const char *table;
	const char *schema = NULL;
	const char *db = NULL;
	const char *wild = NULL;
	int itemp = 0;
	MY_CON *con;
	AV *av;
	char *sql, *p1;
PPCODE:
	// COLUMN, NULLABLE, DEFAULT, IS_PRIMARY, IS_UNIQUE, TYPENAME, AUTOINC
	
	int _intcb( void *arg, int columns, char **data, char **names ) {
		// cid|name|type|notnull|dflt_value|pk
		int pk;
		av = (AV *) sv_2mortal( (SV *) newAV() );
		av_push( av, newSVpvn( data[1], strlen( data[1] ) ) );
		av_push( av, newSViv( data[3][0] == '0' ) );
		if( data[4] )
			av_push( av, newSVpvn( data[4], strlen( data[4] ) ) );
		else
			av_push( av, &PL_sv_undef );
		pk = data[5][0] == '1' ? 1 : 0;
		av_push( av, newSViv( pk ) );
		av_push( av, &PL_sv_undef );
		av_push( av, newSVpvn( data[2], strlen( data[2] ) ) );
		av_push( av, newSViv( my_stricmp( data[2], "integer" ) == 0 && pk == 1 ) );
		XPUSHs( newRV( (SV *) av ) );
		return 0;
	}
	
    if( items < ( SvIOK( ST(0) ) ? 2 : 1 ) || items > 5 )
		Perl_croak( aTHX_ "Usage: " __PACKAGE__ "::show_fields(linkid = 0, table, schema = NULL, db = NULL, wild = NULL)" );
	if( SvIOK( ST( itemp ) ) ) {
		linkid = (UV) SvUV( ST( itemp ) );
		itemp ++;
	}
	table = (const char *) SvPV_nolen( ST( itemp ) );
	itemp ++;
	if( itemp < items ) {
		schema = (const char *) SvPV_nolen( ST( itemp ) );
		itemp ++;
	}
	if( itemp < items ) {
		db = (const char *) SvPV_nolen( ST( itemp ) );
		itemp ++;
	}
	if( itemp < items )
		wild = (const char *) SvPV_nolen( ST( itemp ) );
	con = (MY_CON *) my_verify_linkid( linkid );
	if( con == NULL ) goto error;

	New( 1, sql, 23 + strlen( table ), char );
	p1 = my_strcpy( sql, "PRAGMA table_info('" );
	p1 = my_strcpy( p1, table );
	p1 = my_strcpy( p1, "')" );
	sqlite3_exec( con->con, sql, &_intcb, 0, 0 );
	Safefree( sql );
error:
	{}


#/******************************************************************************
# * show_index( [linkid, ] table [, schema [, db]]] )
# ******************************************************************************/

void
show_index( ... )
PREINIT:
	UV linkid = 0;
	const char *table;
	const char *schema = NULL;
	const char *db = NULL;
	int itemp = 0;
	MY_CON *con;
	AV *av;
	char *sql, **il_data, *p1;
PPCODE:

	// NAME, COLUMN, TYPE

	int _intcb_ii( void *arg, int columns, char **data, char **names ) {
		// seqno|cid|name
		if( columns < 3 ) return 0;
		av = (AV *) sv_2mortal( (SV *) newAV() );
		av_push( av, newSVpvn( il_data[1], strlen( il_data[1] ) ) );
		av_push( av, newSVpvn( data[2], strlen( data[2] ) ) );
		av_push( av, newSViv( il_data[2][0] == '1' ? 2 : 3 ) );
		XPUSHs( newRV( (SV *) av ) );
		return 0;
	}
	
	int _intcb_il( void *arg, int columns, char **data, char **names ) {
		// seq|name|unique
		char *sql2, *p2;
		if( columns < 3 ) return 0;
		il_data = data;
		New( 1, sql2, 22 + strlen( data[1] ), char );
		p2 = my_strcpy( sql2, "PRAGMA index_info('" );
		p2 = my_strcpy( p2, data[1] );
		p2 = my_strcpy( p2, "')" );
		sqlite3_exec( con->con, sql2, &_intcb_ii, 0, 0 );
		Safefree( sql2 );
		return 0;
	}
	
	int _intcb_ti( void *arg, int columns, char **data, char **names ) {
		// cid|name|type|notnull|dflt_value|pk
		if( columns < 6 ) return 0;
		if( data[5][0] == '1' ) {
			av = (AV *) sv_2mortal( (SV *) newAV() );
			av_push( av, newSVpvn( "PRIMARY", 7 ) );
			av_push( av, newSVpvn( data[1], strlen( data[1] ) ) );
			av_push( av, newSViv( 1 ) );
			XPUSHs( newRV( (SV *) av ) );
		}
		return 0;
	}
	
    if( items < ( SvIOK( ST(0) ) ? 2 : 1 ) || items > 4 )
		Perl_croak( aTHX_ "Usage: " __PACKAGE__ "::show_index(linkid = 0, table, schema = NULL, db = NULL)" );
	if( SvIOK( ST( itemp ) ) ) {
		linkid = (UV) SvUV( ST( itemp ) );
		itemp ++;
	}
	table = (const char *) SvPV_nolen( ST( itemp ) );
	itemp ++;
	if( itemp < items ) {
		schema = (const char *) SvPV_nolen( ST( itemp ) );
		itemp ++;
	}
	if( itemp < items )
		db = (const char *) SvPV_nolen( ST( itemp ) );
	con = (MY_CON *) my_verify_linkid( linkid );
	if( con == NULL ) goto error;

	New( 1, sql, 23 + strlen( table ), char );
	p1 = my_strcpy( sql, "PRAGMA table_info('" );
	p1 = my_strcpy( p1, table );
	p1 = my_strcpy( p1, "')" );
	sqlite3_exec( con->con, sql, &_intcb_ti, 0, 0 );
	p1 = my_strcpy( sql, "PRAGMA index_list('" );
	p1 = my_strcpy( p1, table );
	p1 = my_strcpy( p1, "')" );
	sqlite3_exec( con->con, sql, &_intcb_il, 0, 0 );
	Safefree( sql );
error:
	{}


#/******************************************************************************
# * errno( [linkid] )
# ******************************************************************************/

int
errno( linkid = 0 )
long linkid
PREINIT:
	dMY_CXT;
	MY_CON *con;
CODE:
	con = (MY_CON *) my_verify_linkid( linkid );
	RETVAL = con != NULL
		? sqlite3_errcode( con->con )
		: MY_CXT.last_errno;
OUTPUT:
	RETVAL


#/******************************************************************************
# * error( [linkid] )
# ******************************************************************************/

SV *
error( linkid = 0 )
long linkid
PREINIT:
	dMY_CXT;
	MY_CON *con;
	const char *error;
CODE:
	con = (MY_CON *) my_verify_linkid( linkid );
	if( con != NULL ) {
		error = sqlite3_errmsg( con->con );
		if( error[0] == '\0' ) error = con->my_error;
	}
	else
		error = MY_CXT.last_error;
	if( error != NULL && error != '\0' )
		ST(0) = sv_2mortal( newSVpvn( error, strlen( error ) ) );
	else
		ST(0) = &PL_sv_undef;


#/******************************************************************************
# * _cleanup();
# ******************************************************************************/

void
_cleanup()
PREINIT:
	//dMY_CXT;
CODE:
	my_cleanup();
#ifdef USE_THREADS
	//MUTEX_DESTROY( &MY_CXT.share_lock );
#endif


#/******************************************************************************
# * _session_cleanup();
# ******************************************************************************/

void
_session_cleanup()
CODE:
	my_session_cleanup();


#/******************************************************************************
# * get_current_thread_id();
# ******************************************************************************/

unsigned long
get_current_thread_id()
CODE:
	RETVAL = get_current_thread_id();
OUTPUT:
	RETVAL
