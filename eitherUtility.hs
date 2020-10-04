module EitherUtility where

foldE f =
    foldr (
        \fa fb -> 
            case fa of
                Left a -> Left a
                Right a ->
                    case fb of
                        Left b -> Left b
                        Right b -> Right $ f a b
        )

mapE :: (b -> b) -> [Either a b] -> Either a [b]
mapE f [] = Right []
mapE f (x:xs) = 
    case folded of
        Right _ -> Right $ map f remaped
        Left a -> Left a
    where 
        remaped = map (\(Right a) -> a) (x:xs)
        folded = foldE (\_ b -> b) x xs

verify :: [Either a ()] -> Either a ()
verify = foldE (\_ b -> b) (Right ())

(|>>) :: Either a b -> Either a bx -> Either a bx
fa |>> fb =
    case fa of
        Left a -> Left a
        Right a ->
            case fb of
                Left b -> Left b
                Right b -> Right b
