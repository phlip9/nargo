use nom::bytes::complete::tag;
use nom::IResult;

fn main() {
    println!("{:?}", abcd_parser("abcd_asdf"))
}

fn abcd_parser(i: &str) -> IResult<&str, &str> {
    tag("abcd")(i)
}
