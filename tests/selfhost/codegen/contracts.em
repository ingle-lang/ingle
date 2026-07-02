// Codegen fixture: `requires`/`ensures` contracts (MANIFESTO §5e). Each clause lowers to the predicate
// followed by OP_CONTRACT_CHECK <midx>, where midx is the string-pool index of a SYNTHESIZED violation
// message ("precondition/postcondition failed in '<fn>' (requires/ensures, line <L>)"). requires is checked
// at entry; ensures is re-checked at EVERY return (each explicit return plus the implicit trailing one),
// with `result` bound just above the locals. The message strings live in the function's own string pool, so
// this fixture guards the self-hosted SERIALIZER (Stage 8): the .emb's string pool must be byte-identical to
// stage-0's — the disassembly differential alone never compares string pools, which is how a missing-message
// bug once slipped through. Body strings (println) interleave with the ensures messages to pin the pool
// ORDER, and a method contract exercises the bare-method-name message.

fn checked_sqrt_floor(n: int) -> int
    requires n >= 0
{
    var r = 0
    loop {
        if (r + 1) * (r + 1) > n {
            break
        }
        r = r + 1
    }
    return r
}


fn half(n: int) -> int
    requires n >= 0
    ensures result * 2 <= n
    ensures result * 2 >= n - 1
{
    return n / 2
}


fn clamp01(n: int) -> int
    requires n >= 0
    ensures result >= 0
    ensures result <= 100
{
    println("clamping {n}")
    if n > 100 {
        println("over: capping to 100")
        return 100
    }
    return n
}


struct Account {
    balance: int


    fn withdraw(mut self, amount: int) -> int
        requires amount >= 0
        requires amount <= self.balance
        ensures result >= 0
    {
        self.balance = self.balance - amount
        return self.balance
    }
}


fn main() -> int {
    println("sqrt_floor(10)={checked_sqrt_floor(10)}")
    println("half(9)={half(9)}")
    println("clamp01(150)={clamp01(150)}")
    var acc = Account { balance: 100 }
    println("after withdraw={acc.withdraw(30)}")
    return 0
}
