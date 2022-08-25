# until

*Keep track of important milestones in the terminal.*

## Building

```
git clone https://github.com/kdchambers/until
cd until
zig build run
```

Until has no build dependencies.

## Usage
### Add a new event

```
unt add <event_description> <date>
unt add "Last coffee" 15/04/2022
unt add "Trip to New York" 22/01/2023
```

### List events

```
unt list
> 1. 145 days since Last coffee
> 2. 58 days until Trip to New York
```

### Reset saved data

```
unt reset
```
