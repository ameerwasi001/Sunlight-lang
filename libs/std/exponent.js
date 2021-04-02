import {SltFunc, SltThunk, SltNum} from '../../SltRuntime.ts'

const unsafeExponent = new SltThunk(
    () =>
        new SltFunc(
            a =>
                new SltFunc(
                    b => new SltNum(a().value ** b().value, a().pos),
                    [7, 1, "intify.lua"]
                ),
                [7, 1, "intify.lua"]
            ),
)

export {unsafeExponent}