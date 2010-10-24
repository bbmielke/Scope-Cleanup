#define PERL_NO_GET_CONTEXT 1
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#define PERL_VERSION_DECIMAL(r,v,s) (r*1000000 + v*1000 + s)
#define PERL_DECIMAL_VERSION \
	PERL_VERSION_DECIMAL(PERL_REVISION,PERL_VERSION,PERL_SUBVERSION)
#define PERL_VERSION_GE(r,v,s) \
	(PERL_DECIMAL_VERSION >= PERL_VERSION_DECIMAL(r,v,s))

#define Q_MUST_PRESERVE_GHOST_CONTEXT 1

static void run_cleanup(pTHX_ void *cleanup_code_ref)
{
#if Q_MUST_PRESERVE_GHOST_CONTEXT
	bool have_ghost_context;
	PERL_CONTEXT ghost_context;
	have_ghost_context = cxstack_ix < cxstack_max;
	if(have_ghost_context) ghost_context = cxstack[cxstack_ix+1];
#endif /* Q_MUST_PRESERVE_GHOST_CONTEXT */
	ENTER;
	SAVETMPS;
	{
		dSP;
		PUSHMARK(SP);
	}
	call_sv((SV*)cleanup_code_ref, G_VOID|G_DISCARD);
#if Q_MUST_PRESERVE_GHOST_CONTEXT
	if(have_ghost_context) cxstack[cxstack_ix+1] = ghost_context;
#endif /* Q_MUST_PRESERVE_GHOST_CONTEXT */
	FREETMPS;
	LEAVE;
}

static OP *pp_establish_cleanup(pTHX)
{
	dSP;
	SV *cleanup_code_ref;
	cleanup_code_ref = newSVsv(POPs);
	SAVEFREESV(cleanup_code_ref);
	SAVEDESTRUCTOR_X(run_cleanup, cleanup_code_ref);
	if(GIMME_V != G_VOID) PUSHs(&PL_sv_undef);
	RETURN;
}

#define gen_establish_cleanup_op(argop) \
		THX_gen_establish_cleanup_op(aTHX_ argop)
static OP *THX_gen_establish_cleanup_op(pTHX_ OP *argop)
{
	OP *estop;
	NewOpSz(0, estop, sizeof(UNOP));
	estop->op_type = OP_RAND;
	estop->op_ppaddr = pp_establish_cleanup;
	cUNOPx(estop)->op_flags = OPf_KIDS;
	cUNOPx(estop)->op_first = argop;
	PL_hints |= HINT_BLOCK_SCOPE;
	return estop;
}

#define ck_entersub_establish_cleanup(entersubop) \
		THX_ck_entersub_establish_cleanup(aTHX_ entersubop)
static OP *THX_ck_entersub_establish_cleanup(pTHX_ OP *entersubop)
{
	OP *pushop, *argop;
	pushop = cUNOPx(entersubop)->op_first;
	if(!pushop->op_sibling) pushop = cUNOPx(pushop)->op_first;
	argop = pushop->op_sibling;
	if(!argop) return entersubop;
	pushop->op_sibling = argop->op_sibling;
	argop->op_sibling = NULL;
	op_free(entersubop);
	return gen_establish_cleanup_op(argop);
}

/*
 * special operators handled as functions
 *
 * This code intercepts the compilation of calls to magic functions,
 * and compiles them to custom ops that are better run that way than as
 * real functions.
 */

#define rvop_cv(rvop) THX_rvop_cv(aTHX_ rvop)
static CV *THX_rvop_cv(pTHX_ OP *rvop)
{
	switch(rvop->op_type) {
		case OP_CONST: {
			SV *rv = cSVOPx_sv(rvop);
			return SvROK(rv) ? (CV*)SvRV(rv) : NULL;
		} break;
		case OP_GV: return GvCV(cGVOPx_gv(rvop));
		default: return NULL;
	}
}

static CV *establishcleanup_cv;

static OP *(*nxck_entersub)(pTHX_ OP *o);

static OP *myck_entersub(pTHX_ OP *op)
{
	OP *pushop, *cvop;
	CV *cv;
	pushop = cUNOPx(op)->op_first;
	if(!pushop->op_sibling) pushop = cUNOPx(pushop)->op_first;
	for(cvop = pushop; cvop->op_sibling; cvop = cvop->op_sibling) ;
	if(!(cvop->op_type == OP_RV2CV &&
			!(cvop->op_private & OPpENTERSUB_AMPER)))
		return nxck_entersub(aTHX_ op);
	cv = rvop_cv(cUNOPx(cvop)->op_first);
	if(cv == establishcleanup_cv) {
		op = nxck_entersub(aTHX_ op);   /* for prototype checking */
		return ck_entersub_establish_cleanup(op);
	} else {
		return nxck_entersub(aTHX_ op);
	}
}

MODULE = Scope::Cleanup PACKAGE = Scope::Cleanup

PROTOTYPES: DISABLE

BOOT:
	establishcleanup_cv = get_cv("Scope::Cleanup::establish_cleanup", 0);
	nxck_entersub = PL_check[OP_ENTERSUB];
	PL_check[OP_ENTERSUB] = myck_entersub;

void
establish_cleanup(...)
PROTOTYPE: $
CODE:
	PERL_UNUSED_VAR(items);
	croak("establish_cleanup called as a function");
