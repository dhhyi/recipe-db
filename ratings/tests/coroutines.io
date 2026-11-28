RatingsCoroutineTest := UnitTest clone do(
    testCoroutineSwitching := method(
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
        assertEquals(firstResult, 5050)
        assertEquals(secondResult, 10100)
    )
)

failure := try(failures := RatingsCoroutineTest run)
if(failure,
    failure showStack
    System exit(1)
)
System exit(if(failures isEmpty, 0, 1))
