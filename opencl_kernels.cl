// vim:ft=opencl
#pragma OPENCL EXTENSION cl_khr_byte_addressable_store : enable

// ###########
// # BF ECB #
// ###########

#define n2l(c,l)        (l =((uint)(*(c)))<<24L, \
                         l|=((uint)(*(c+1)))<<16L, \
                         l|=((uint)(*(c+2)))<< 8L, \
                         l|=((uint)(*(c+3))))

#define flip64(a)	(a= \
			((a & 0x00000000000000FF) << 56) | \
			((a & 0x000000000000FF00) << 40) | \
			((a & 0x0000000000FF0000) << 24) | \
			((a & 0x00000000FF000000) << 8)  | \
			((a & 0x000000FF00000000) >> 8)  | \
			((a & 0x0000FF0000000000) >> 24) | \
			((a & 0x00FF000000000000) >> 40) | \
			((a & 0xFF00000000000000) >> 56))

#include <openssl/blowfish.h>

#define BF_ENC(LL,R,S,P) ( \
	LL^=P, \
	LL^=(((	S[       ((uint)(R>>24)&0xff)] + \
		S[0x0100+((uint)(R>>16)&0xff)])^ \
		S[0x0200+((uint)(R>> 8)&0xff)])+ \
		S[0x0300+((uint)(R    )&0xff)]) \
	)


// TODO: When using __constant memory for the key-schedule, each call to BF_ENC
// increases the compilation-time by at least factor 2. Bug "filed" in NVIDIA
// forums
__kernel void BFencKernel(__global unsigned long *data, __global unsigned int *bf_constant_schedule) {
	__private unsigned int l, r;
	__private unsigned long block = data[get_global_id(0)];
	
	n2l((unsigned char *)&block,l);
	n2l(((unsigned char *)&block)+4,r);

	__global unsigned int *p=&bf_constant_schedule[0];
	__global unsigned int *s=p+18;

	l^=p[0];
	BF_ENC(r,l,s,p[ 1]);
	BF_ENC(l,r,s,p[ 2]);
	BF_ENC(r,l,s,p[ 3]);
	BF_ENC(l,r,s,p[ 4]);
	BF_ENC(r,l,s,p[ 5]);
	BF_ENC(l,r,s,p[ 6]);
	BF_ENC(r,l,s,p[ 7]);
	BF_ENC(l,r,s,p[ 8]);
	BF_ENC(r,l,s,p[ 9]);
	BF_ENC(l,r,s,p[10]);
	BF_ENC(r,l,s,p[11]);
	BF_ENC(l,r,s,p[12]);
	BF_ENC(r,l,s,p[13]);
	BF_ENC(l,r,s,p[14]);
	BF_ENC(r,l,s,p[15]);
	BF_ENC(l,r,s,p[16]);
	r^=p[17];

	block = ((unsigned long)r) << 32 | l;
	flip64(block);
	data[get_global_id(0)] = block;
}

// ###########
// # DES ECB #
// ###########
#define IP(left,right) \
	{ \
	register unsigned int tt; \
	PERM_OP(right,left,tt, 4,0x0f0f0f0fL); \
	PERM_OP(left,right,tt,16,0x0000ffffL); \
	PERM_OP(right,left,tt, 2,0x33333333L); \
	PERM_OP(left,right,tt, 8,0x00ff00ffL); \
	PERM_OP(right,left,tt, 1,0x55555555L); \
	}

#define FP(left,right) \
	{ \
	register unsigned int tt; \
	PERM_OP(left,right,tt, 1,0x55555555L); \
	PERM_OP(right,left,tt, 8,0x00ff00ffL); \
	PERM_OP(left,right,tt, 2,0x33333333L); \
	PERM_OP(right,left,tt,16,0x0000ffffL); \
	PERM_OP(left,right,tt, 4,0x0f0f0f0fL); \
	}

#define	ROTATE(a,n)	(((a)>>(n))|((a)<<(32-(n))))

#define PERM_OP(a,b,t,n,m) ((t)=((((a)>>(n))^(b))&(m)),\
	(b)^=(t),\
	(a)^=((t)<<(n)))

#define D_ENCRYPT(LL,R,S) { \
	__private unsigned long ss = s[S]; \
	u=R^ss; \
	t=R^ss>>32; \
	t=ROTATE(t,4); \
	LL^= \
	*(__local unsigned int *)(des_SP      +((u     )&0xfc))^ \
	*(__local unsigned int *)(des_SP+0x200+((u>> 8L)&0xfc))^ \
	*(__local unsigned int *)(des_SP+0x400+((u>>16L)&0xfc))^ \
	*(__local unsigned int *)(des_SP+0x600+((u>>24L)&0xfc))^ \
	*(__local unsigned int *)(des_SP+0x100+((t     )&0xfc))^ \
	*(__local unsigned int *)(des_SP+0x300+((t>> 8L)&0xfc))^ \
	*(__local unsigned int *)(des_SP+0x500+((t>>16L)&0xfc))^ \
	*(__local unsigned int *)(des_SP+0x700+((t>>24L)&0xfc)); }

__kernel void DESencKernel(__global unsigned long *data, __local unsigned int *des_d_sp, __local unsigned long *s, __global unsigned int *des_d_sp_c, __global unsigned long *cs) {
	
	if(get_local_id(0) < 16)
		s[get_local_id(0)] = cs[get_local_id(0)];

	// Careful: Based on the assumption of a constant 128 threads!
	// What happens for kernel calls with less than 128 threads, like the final padding 8-byte call?
	// It seems to work, but might be because of a strange race condition. Watch out!
	des_d_sp[get_local_id(0)] = des_d_sp_c[get_local_id(0)];
	des_d_sp[get_local_id(0)+128] = des_d_sp_c[get_local_id(0)+128];
	des_d_sp[get_local_id(0)+256] = des_d_sp_c[get_local_id(0)+256];
	des_d_sp[get_local_id(0)+384] = des_d_sp_c[get_local_id(0)+384];

	__private unsigned long load = data[get_global_id(0)];
	__private unsigned int right = load;
	__private unsigned int left = load>>32;
	
	__private unsigned int t,u;
	__local unsigned char *des_SP = (__local unsigned char *) des_d_sp;

	IP(right,left);

	left=ROTATE(left,29);
	right=ROTATE(right,29);

	barrier(CLK_LOCAL_MEM_FENCE);

	D_ENCRYPT(left,right, 0);
	D_ENCRYPT(right,left, 1);
	D_ENCRYPT(left,right, 2);
	D_ENCRYPT(right,left, 3);
	D_ENCRYPT(left,right, 4);
	D_ENCRYPT(right,left, 5);
	D_ENCRYPT(left,right, 6);
	D_ENCRYPT(right,left, 7);
	D_ENCRYPT(left,right, 8);
	D_ENCRYPT(right,left, 9);
	D_ENCRYPT(left,right,10);
	D_ENCRYPT(right,left,11);
	D_ENCRYPT(left,right,12);
	D_ENCRYPT(right,left,13);
	D_ENCRYPT(left,right,14);
	D_ENCRYPT(right,left,15);

	left=ROTATE(left,3);
	right=ROTATE(right,3);
	FP(right,left);
	data[get_global_id(0)]=left|((unsigned long)right)<<32;
}

// #############
// # CAST5 ECB #
// #############
#define ROTL(a,n)     ((((a)<<(n))&0xffffffffL)|((a)>>(32-(n))))

#define C_M    0x3fc
#define C_0    22L
#define C_1    14L
#define C_2     6L
#define C_3     2L /* left shift */

#define E_CAST(n,key,L,R,OP1,OP2,OP3) \
	{ \
	unsigned int a,b,c,d; \
	t=(key[n*2] OP1 R)&0xffffffff; \
	t=ROTL(t,(key[n*2+1])); \
	a=CAST_S_table0[(t>> 8)&0xff]; \
	b=CAST_S_table1[(t    )&0xff]; \
	c=CAST_S_table2[(t>>24)&0xff]; \
	d=CAST_S_table3[(t>>16)&0xff]; \
	L^=(((((a OP2 b)&0xffffffffL) OP3 c)&0xffffffffL) OP1 d)&0xffffffffL; \
	}

__kernel void CASTencKernel(__global unsigned long *data, __constant unsigned int *cast_constant_schedule, __global unsigned int *CAST_S_table) {
	__local unsigned int CAST_S_table0[256], CAST_S_table1[256], CAST_S_table2[256], CAST_S_table3[256];
	__private unsigned int l,r,t;
	__constant unsigned int *k = &cast_constant_schedule[0];

	__private unsigned long block = data[get_global_id(0)];

	n2l((unsigned char *)&block,l);
	n2l(((unsigned char *)&block)+4,r);

	CAST_S_table0[get_local_id(0)] = CAST_S_table[get_local_id(0)];
	CAST_S_table0[get_local_id(0)+128] = CAST_S_table[get_local_id(0)+128];
	CAST_S_table1[get_local_id(0)] = CAST_S_table[get_local_id(0)+256];
	CAST_S_table1[get_local_id(0)+128] = CAST_S_table[get_local_id(0)+384];
	CAST_S_table2[get_local_id(0)] = CAST_S_table[get_local_id(0)+512];
	CAST_S_table2[get_local_id(0)+128] = CAST_S_table[get_local_id(0)+640];
	CAST_S_table3[get_local_id(0)] = CAST_S_table[get_local_id(0)+768];
	CAST_S_table3[get_local_id(0)+128] = CAST_S_table[get_local_id(0)+896];

	barrier(CLK_LOCAL_MEM_FENCE);

	E_CAST( 0,k,l,r,+,^,-);
	E_CAST( 1,k,r,l,^,-,+);
	E_CAST( 2,k,l,r,-,+,^);
	E_CAST( 3,k,r,l,+,^,-);
	E_CAST( 4,k,l,r,^,-,+);
	E_CAST( 5,k,r,l,-,+,^);
	E_CAST( 6,k,l,r,+,^,-);
	E_CAST( 7,k,r,l,^,-,+);
	E_CAST( 8,k,l,r,-,+,^);
	E_CAST( 9,k,r,l,+,^,-);
	E_CAST(10,k,l,r,^,-,+);
	E_CAST(11,k,r,l,-,+,^);
	E_CAST(12,k,l,r,+,^,-);
	E_CAST(13,k,r,l,^,-,+);
	E_CAST(14,k,l,r,-,+,^);
	E_CAST(15,k,r,l,+,^,-);

	block = ((unsigned long)r) << 32 | l;

	flip64(block);
	data[get_global_id(0)] = block;
}

#define SBOX1_1110 Camellia_SBOX[0]
#define SBOX4_4404 Camellia_SBOX[1]
#define SBOX2_0222 Camellia_SBOX[2]
#define SBOX3_3033 Camellia_SBOX[3]

#define SWAP(x) ((LeftRotate(x,8) & 0x00ff00ff) | (RightRotate(x,8) & 0xff00ff00))
#define RightRotate(x, s) ( ((x) >> (s)) + ((x) << (32 - s)) )
#define LeftRotate(x, s)  ( ((x) << (s)) + ((x) >> (32 - s)) )
#define GETU32(p)   SWAP(*((unsigned int *)(p)))
#define PUTU32(p,v) (*((unsigned int *)(p)) = SWAP((v)))

#define Camellia_Feistel(_s0,_s1,_s2,_s3,_key) do {\
	unsigned int _t0,_t1,_t2,_t3;\
\
	_t0  = _s0 ^ (_key)[1];\
	_t3  = SBOX4_4404[_t0&0xff];\
	_t1  = _s1 ^ (_key)[0];\
	_t3 ^= SBOX3_3033[(_t0 >> 8)&0xff];\
	_t2  = SBOX1_1110[_t1&0xff];\
	_t3 ^= SBOX2_0222[(_t0 >> 16)&0xff];\
	_t2 ^= SBOX4_4404[(_t1 >> 8)&0xff];\
	_t3 ^= SBOX1_1110[(_t0 >> 24)];\
	_t2 ^= _t3;\
	_t3  = RightRotate(_t3,8);\
	_t2 ^= SBOX3_3033[(_t1 >> 16)&0xff];\
	_s3 ^= _t3;\
	_t2 ^= SBOX2_0222[(_t1 >> 24)];\
	_s2 ^= _t2; \
	_s3 ^= _t2;\
} while(0)

__kernel void CMLLencKernel(__global unsigned long *data, __constant unsigned int *k, __global unsigned int *Camellia_global_SBOX) {
	__private unsigned long block = data[get_global_id(0)*2];
	__private unsigned long block2 = data[(get_global_id(0)*2)+1];
	__local unsigned int Camellia_SBOX[4][256];

	Camellia_SBOX[0][get_local_id(0)] = Camellia_global_SBOX[get_local_id(0)];
	Camellia_SBOX[0][get_local_id(0)+128] = Camellia_global_SBOX[get_local_id(0)+128];
	Camellia_SBOX[1][get_local_id(0)] = Camellia_global_SBOX[get_local_id(0)+256];
	Camellia_SBOX[1][get_local_id(0)+128] = Camellia_global_SBOX[get_local_id(0)+384];
	Camellia_SBOX[2][get_local_id(0)] = Camellia_global_SBOX[get_local_id(0)+512];
	Camellia_SBOX[2][get_local_id(0)+128] = Camellia_global_SBOX[get_local_id(0)+640];
	Camellia_SBOX[3][get_local_id(0)] = Camellia_global_SBOX[get_local_id(0)+768];
	Camellia_SBOX[3][get_local_id(0)+128] = Camellia_global_SBOX[get_local_id(0)+896];

	barrier(CLK_LOCAL_MEM_FENCE);

	__private unsigned int s0,s1,s2,s3; 
	//__constant unsigned int *k = cmll_constant_schedule;

	s0 = GETU32((unsigned char *)&block)    ^ k[1];
	s1 = GETU32(((unsigned char *)&block)+4)  ^ k[0];
	s2 = GETU32((unsigned char *)&block2)  ^ k[3];
	s3 = GETU32(((unsigned char *)&block2)+4) ^ k[2];
	k += 4;

	Camellia_Feistel(s0,s1,s2,s3,k+0);
	Camellia_Feistel(s2,s3,s0,s1,k+2);
	Camellia_Feistel(s0,s1,s2,s3,k+4);
	Camellia_Feistel(s2,s3,s0,s1,k+6);
	Camellia_Feistel(s0,s1,s2,s3,k+8);
	Camellia_Feistel(s2,s3,s0,s1,k+10);
	k += 12;

	s1 ^= LeftRotate(s0 & k[1], 1);
	s2 ^= s3 | k[2];
	s0 ^= s1 | k[0];
	s3 ^= LeftRotate(s2 & k[3], 1);
	k += 4;

	Camellia_Feistel(s0,s1,s2,s3,k+0);
	Camellia_Feistel(s2,s3,s0,s1,k+2);
	Camellia_Feistel(s0,s1,s2,s3,k+4);
	Camellia_Feistel(s2,s3,s0,s1,k+6);
	Camellia_Feistel(s0,s1,s2,s3,k+8);
	Camellia_Feistel(s2,s3,s0,s1,k+10);
	k += 12;

	s1 ^= LeftRotate(s0 & k[1], 1);
	s2 ^= s3 | k[2];
	s0 ^= s1 | k[0];
	s3 ^= LeftRotate(s2 & k[3], 1);
	k += 4;

	Camellia_Feistel(s0,s1,s2,s3,k+0);
	Camellia_Feistel(s2,s3,s0,s1,k+2);
	Camellia_Feistel(s0,s1,s2,s3,k+4);
	Camellia_Feistel(s2,s3,s0,s1,k+6);
	Camellia_Feistel(s0,s1,s2,s3,k+8);
	Camellia_Feistel(s2,s3,s0,s1,k+10);
	k += 12;

	s2 ^= k[1], s3 ^= k[0], s0 ^= k[3], s1 ^= k[2];

	block = ((unsigned long)s2) << 32 | s3;
	block2 = ((unsigned long)s0) << 32 | s1;
	flip64(block);
	flip64(block2);

	data[get_global_id(0)*2] = block;
	data[(get_global_id(0)*2)+1] = block2;
}
