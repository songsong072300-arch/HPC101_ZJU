
#ifndef TWO_PUNCTURES_H
#define TWO_PUNCTURES_H

#define StencilSize 19
#define N_PlaneRelax 1
#define NRELAX 250
#define Step_Relax 1

#define Pi 3.14159265358979323846264338328
#define Pih 1.57079632679489661923132169164 /* Pi/2*/
#define Piq 0.78539816339744830961566084582 /* Pi/4*/

#define TINY 1.0e-20

class TwoPunctures
{
public:
       typedef struct DERIVS
       {
              double *d0, *d1, *d2, *d3, *d11, *d12, *d13, *d22, *d23, *d33;
       } derivs;

       double *F;
       derivs u, v;

private:
       double par_m_plus, par_m_minus, par_b;
       double par_P_plus[3], par_P_minus[3];
       double par_S_plus[3], par_S_minus[3];

       int npoints_A, npoints_B, npoints_phi;

       double target_M_plus, target_M_minus;
       
       double admMass;

       double adm_tol;

       double Newton_tol;
       int Newton_maxit;

       int ntotal;

       // Pre-allocated workspace for LineRelax / ThomasAlgorithm.
       // Eliminates millions of new[]/delete[] on the hot solver path.
   // One set per OpenMP thread (flat buffer: [nthreads * ws_nmax]).
   int ws_nmax, ws_nthreads;
   double *ws_diag, *ws_e, *ws_f, *ws_b, *ws_x;   // LineRelax_be / _al
   double *ws_d, *ws_y;                              // ThomasAlgorithm

       // Pre-allocated derivs for JFD_times_dv / J_times_dv / F_of_v.
       derivs ws_dU, ws_U;
       double *ws_values;

       // Precomputed trig tables: al depends only on i, be only on j.
       // Eliminates ~25% of runtime spent in __cos / __sin on the hot path.
       double *pc_sin_al, *pc_cos_al, *pc_Am1;   // size n1
       double *pc_sin_be, *pc_cos_be;            // size n2
       double *pc_sin_al3, *pc_sin_be3;          // sin(al)^3, sin(be)^3
        double *pc_fac;                             // size n1*n2: sin_al^3 * sin_be^3

        // O19: Precomputed cos/sin lookup tables for chebft_Zeros/Extremes/fourft.
        // Eliminates __cos (22.92% of TwoPuncture) on the spectral transform hot path.
        double *pc_cos_cheb_zeros;    // size n_cheb*n_cheb, cos(Pi/n * j * (k+0.5))
        double *pc_cos_cheb_extremes; // size (n_cheb-1)*(n_cheb-1), cos(Pi/(n-1) * j * k)
        double *pc_cos_fourft;        // size n3*n3, cos(Pi/M * l * k)
        double *pc_sin_fourft;        // size n3*n3, sin(Pi/M * l * k)
        int pc_n_cheb_zeros, pc_n_cheb_extremes, pc_n_fourft;

       struct parameters
       {
              int nvar, n1, n2, n3;
              double b;
       };

public:
       TwoPunctures(double mp, double mm, double b, double P_plusx, double P_plusy, double P_plusz,
                    double S_plusx, double S_plusy, double S_plusz,
                    double P_minusx, double P_minusy, double P_minusz,
                    double S_minusx, double S_minusy, double S_minusz,
                    int nA, int nB, int nphi,
                    double Mp, double Mm, double admtol, double Newtontol,
                    int Newtonmaxit);
       ~TwoPunctures();

       void Solve();
       void set_initial_guess(derivs v);
       int index(int i, int j, int k, int l, int a, int b, int c, int d);
       int *ivector(long nl, long nh);
       double *dvector(long nl, long nh);
       int **imatrix(long nrl, long nrh, long ncl, long nch);
       double **dmatrix(long nrl, long nrh, long ncl, long nch);
       double ***d3tensor(long nrl, long nrh, long ncl, long nch, long ndl, long ndh);
       void free_ivector(int *v, long nl, long nh);
       void free_dvector(double *v, long nl, long nh);
       void free_imatrix(int **m, long nrl, long nrh, long ncl, long nch);
       void free_dmatrix(double **m, long nrl, long nrh, long ncl, long nch);
       void free_d3tensor(double ***t, long nrl, long nrh, long ncl, long nch,
                          long ndl, long ndh);
       int minimum2(int i, int j);
       int minimum3(int i, int j, int k);
       int maximum2(int i, int j);
       int maximum3(int i, int j, int k);
       int pow_int(int mantisse, int exponent);
       void chebft_Zeros(double u[], int n, int inv);
       void chebft_Extremes(double u[], int n, int inv);
       void chder(double *c, double *cder, int n);
       double chebev(double a, double b, double c[], int m, double x);
       void fourft(double *u, int N, int inv);
       void fourder(double u[], double du[], int N);
       void fourder2(double u[], double d2u[], int N);
       double fourev(double *u, int N, double x);
       double norm1(double *v, int n);
       double norm2(double *v, int n);
       double scalarproduct(double *v, double *w, int n);
       double PunctIntPolAtArbitPosition(int ivar, int nvar, int n1,
                                         int n2, int n3, derivs v, double x, double y,
                                         double z);
       double PunctEvalAtArbitPosition(double *v, int ivar, double A, double B, double phi,
                                       int nvar, int n1, int n2, int n3);
       void AB_To_XR(int nvar, double A, double B, double *X, double *R,
                     derivs U);
       void C_To_c(int nvar, double X, double R, double *x, double *r,
                   derivs U);
       void rx3_To_xyz(int nvar, double x, double r, double phi,
                       double *y, double *z, derivs U);
       void Derivatives_AB3(int nvar, int n1, int n2, int n3, derivs v);
       void Newton(int const nvar, int const n1, int const n2, int const n3,
                   derivs v, double const tol, int const itmax);
       void F_of_v(int nvar, int n1, int n2, int n3, derivs v, double *F,
                   derivs u);
       double norm_inf(double const *F, int const ntotal);
       int bicgstab(int const nvar, int const n1, int const n2, int const n3,
                    derivs v, derivs dv, int const itmax, double const tol,
                    double *normres);
       void allocate_derivs(derivs *v, int n);
       void free_derivs(derivs *v, int n);
       int Index(int ivar, int i, int j, int k, int nvar, int n1, int n2, int n3);
       void NonLinEquations(double rho_adm, double A, double B, double X, double R, double x, double r, double phi,
                            double y, double z, derivs U, double *values);
       double BY_KKofxyz(double x, double y, double z);
       void SetMatrix_JFD(int nvar, int n1, int n2, int n3, derivs u, int *ncols, int **cols, double **Matrix);
       void J_times_dv(int nvar, int n1, int n2, int n3, derivs dv, double *Jdv, derivs u);
       void relax(double *dv, int const nvar, int const n1, int const n2, int const n3,
                  double const *rhs, int const *ncols, int **cols, double **JFD);
       void LineRelax_be(double *dv,
                         int const i, int const k, int const nvar,
                         int const n1, int const n2, int const n3,
                         double const *rhs, int const *ncols, int **cols,
                         double **JFD);
       void JFD_times_dv(int i, int j, int k, int nvar, int n1, int n2,
                         int n3, derivs dv, derivs u, double *values);
       void LinEquations(double A, double B, double X, double R,
                         double x, double r, double phi,
                         double y, double z, derivs dU, derivs U, double *values);
       void LineRelax_al(double *dv,
                         int const j, int const k, int const nvar,
                         int const n1, int const n2, int const n3,
                         double const *rhs, int const *ncols,
                         int **cols, double **JFD);
       void ThomasAlgorithm(int N, double *b, double *a, double *c, double *x, double *q);
       void Save(char *fname);
       // provided by Vasileios Paschalidis (vpaschal@illinois.edu)
       double Spec_IntPolABphiFast(parameters par, double *v, int ivar, double A, double B, double phi);
       double Spec_IntPolFast(parameters par, int ivar, double *v, double x, double y, double z);
       void SpecCoef(parameters par, int ivar, double *v, double *cf);
};

#endif /* TWO_PUNCTURES_H */
