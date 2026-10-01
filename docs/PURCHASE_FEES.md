# Purchase fees

`PurchaseFees` prices each scheduled purchase independently. Its fee amount is a
stablecoin-denominated allocation weight: the venue receives the full retrieved
stablecoin, and the collector receives a share of the measured rBTC/WRBTC output.
The fee parameters are configured per handler by its owner through
`setFeeRateParams(minFeeRate, maxFeeRate, feePurchaseLowerBound)` and read through
`getFeeSettings()`.

## Parameters and units

| Symbol | Contract value | Meaning |
|---|---|---|
| $x$ | Purchase amount | Gross scheduled purchase, in the token's smallest units |
| $L$ | `feePurchaseLowerBound` | Amount at or below which the maximum rate applies; same units as $x$ |
| $M$ | `maxFeeRate` | Maximum rate, in basis points |
| $m$ | `minFeeRate` | Asymptotic minimum rate, in basis points |
| $B$ | `BPS_DENOMINATOR` | 10,000; 100 basis points = 1% |

The contract enforces $0\le m\le M\le500$ (a 5% cap). Purchase amounts are bounded
by `uint96` in `DcaManager`; the stored lower bound is `uint112`. Convert the lower
bound to each token's base units: for example, a threshold of 250 tokens is
`250e6` for a six-decimal token and `250e18` for an eighteen-decimal token.
The equations below describe the implemented model; they do not prescribe launch
parameter values.

## Fee amount and effective rate

The **unrounded absolute fee** is:

$$
f(x)=\begin{cases}
\dfrac{Mx}{B}, & 0\le x\le L,\\[6pt]
\dfrac{mx+(M-m)\left(2L-\dfrac{L^2}{x}\right)}{B}, & x>L.
\end{cases}
$$

For positive purchases, its **unrounded effective rate**, expressed as a fraction
of the purchase, is:

$$
r(x)=\frac{f(x)}{x}=\begin{cases}
\dfrac{M}{B}, & 0<x\le L,\\[6pt]
\dfrac{m+(M-m)\left(\dfrac{2L}{x}-\dfrac{L^2}{x^2}\right)}{B}, & x>L.
\end{cases}
$$

Multiply $r(x)$ by 100 for a percentage. The rate stays at the maximum through
$L$, then decreases toward the minimum. With unequal rates and $L>0$, the
minimum is approached asymptotically; there is no finite upper purchase bound
where it suddenly applies.

The fee amount continues to increase as the rate decreases. For $x>L$:

$$
f'(x)=\frac{m+(M-m)L^2/x^2}{B}\ge0,
\qquad
r'(x)=-\frac{2(M-m)L(x-L)}{Bx^3}\le0.
$$

When $L>0$, both the fee and its slope match the flat segment at $x=L$:
$f(L)=ML/B$ and $f'(L)=M/B$. Larger purchases therefore cannot produce smaller
absolute fees. At large purchase sizes, the fee approaches the line
$mx/B+2(M-m)L/B$; its slope approaches $m/B$.

If $m=M$, every purchase uses the flat rate. If $L=0$, positive purchases use
$m/B$ immediately. If $m=0$ and $L>0$, the absolute fee approaches the finite
limit $2ML/B$. A zero purchase has zero fee; its effective rate is undefined.

## Integer rounding

Solidity calculates the fee with **one final floor**, in token base units:

$$
F(x)=\begin{cases}
\left\lfloor\dfrac{Mx}{B}\right\rfloor, & 0\le x\le L,\\[6pt]
\left\lfloor\dfrac{mx^2+(M-m)L(2x-L)}{xB}\right\rfloor, & x>L.
\end{cases}
$$

The whole-basis-point rate is never calculated or rounded as an intermediate
step. Flooring a nondecreasing function preserves nondecreasing fees: tiny
purchase increases can leave the fee unchanged, but cannot reduce it. Since
$0\le f'(x)\le0.05$, the net weight $x-F(x)$ is also nondecreasing for integer
purchase amounts.

The realized weight rate is $F(x)/x$. It differs from $r(x)$ by less than one
smallest token unit divided by $x$, and can have tiny rounding fluctuations.
The smooth rate curve describes the unrounded rate; it does not claim that
integer fees produce a perfectly smooth graph.

An exact off-chain quote should use integer arithmetic (for example, JavaScript
`bigint`) in base units:

```text
if (x <= L):
    F = x * M / 10000
else:
    F = (m * x * x + (M - m) * L * (2 * x - L)) / (x * 10000)
```

Here `/` means integer division. On the curved branch, $L<x$ and
$L(2x-L)\le x^2$, so the numerator is bounded by $Mx^2<2^{201}$ for supported
purchase amounts. The denominator is nonzero and below $2^{110}$.

## Allocation into rBTC

For a batch, let $G=\sum_i x_i$, $T=\sum_i F(x_i)$, and $Q$ be the measured
rBTC/WRBTC received from the venue. The collector is credited
$\lfloor QT/G\rfloor$ and each buyer is credited
$\lfloor Q(x_i-F(x_i))/G\rfloor$. All fees are calculated per purchase, even
when several purchases share a batch or buyer.

The fee curves above describe the stablecoin-denominated weights. Actual rBTC
credits depend on measured venue output and have their own final rounding.
`PurchaseFees__FeeCredited` reports the collector's actual rBTC credit and its
corresponding floored share of retrieved stablecoin. Small allocation dust stays
uncredited. The collector withdraws through the accumulated-rBTC withdrawal path.

## Plot the curves

In [Desmos](https://www.desmos.com/calculator), create sliders `M`, `m` and `L`,
then paste these expressions on separate lines. For visualization, $x$ and $L$
may be expressed in whole tokens; these plot the unrounded equations.

```text
f(x)={0<=x<=L:M*x/10000,x>L:(m*x+(M-m)*(2*L-L^2/x))/10000}
p(x)={0<x<=L:M/100,x>L:(m+(M-m)*(2*L/x-L^2/x^2))/100}
```

`f(x)` is the fee in token units; `p(x)` is the fee percentage. At $x=0$ only
the fee is defined. Exact contract rounding must be evaluated in token base units.

Implementation: [`PurchaseFees.sol`](../src/PurchaseFees.sol) and
[`IPurchaseFees.sol`](../src/interfaces/IPurchaseFees.sol).
Regression and property tests:
[`PurchaseFeesTest.t.sol`](../test/ai-generated/unit/PurchaseFeesTest.t.sol).
