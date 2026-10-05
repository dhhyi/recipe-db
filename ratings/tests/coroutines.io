worker := Object clone do(
    sum := method(multiplier,
        total := 0
        for(i, 1, 100,
            total = total + (i * multiplier)
            yield
        )
        total
    )
)

first := worker clone @sum(1)
second := worker clone @sum(2)
firstResult := first asNumber
secondResult := second asNumber
if(firstResult != 5050,
    writeln("First coroutine returned ", firstResult, ", expected 5050")
    System exit(1)
)
if(secondResult != 10100,
    writeln("Second coroutine returned ", secondResult, ", expected 10100")
    System exit(1)
)
writeln("Coroutine switching passed")
